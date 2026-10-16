// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import CoreGraphics
import Foundation

enum ForkTrackpadGestureTests {
    typealias Machine = ForkTrackpadGestureMachine
    typealias Action = ForkTrackpadGestureAction
    typealias Swipe = ForkTrackpadSwipeDirection

    static func run(_ suite: TestSuite) {
        sequence(suite)
        catalog(suite)
        titlebar(suite)
        swipes(suite)
        diagonals(suite)
        cancellation(suite)
        dispositions(suite)
        pinches(suite)
        doublePinch(suite)
        doubleTap(suite)
        dock(suite)
        dockIcon(suite)
        dockItemIndex(suite)
        previewContent(suite)
        previewPlacement(suite)
        disabledGestures(suite)
        deadlines(suite)
        chains(suite)
        decoding(suite)
        clock(suite)
        center(suite)
        halves(suite)
        sizeCycle(suite)
        windowChain(suite)
        modifierRemap(suite)
        gridResolve(suite)
        grid(suite)
        gridRow(suite)
        diagnostics(suite)
        complementaryHalves(suite)
        complementRefit(suite)
        halfMemory(suite)
        complementWiring(suite)
        complementaryPairs(suite)
        linkedBorder(suite)
        linkedResize(suite)
        linkedSettle(suite)
        linkedOrder(suite)
        linkedWiring(suite)
        gestureGroups(suite)
        disabledGestureStorage(suite)
        tuningLadders(suite)
        tuningWiring(suite)
        emptyTrash(suite)
        finderWindows(suite)
        minimizedWindows(suite)
        coveredDock(suite)
        windowStack(suite)
        wiring(suite)
        strings(suite)
    }

    /// Plays the host: a clock, a hit test, and a wake-up at every
    /// `nextDeadline`, exactly what the tap's timer does.
    struct Driver {
        let suite: TestSuite
        var machine: Machine
        var now: TimeInterval = 0
        var onTarget: ForkTrackpadGestureTarget? = .titlebar
        var gridModifierHeld = false
        private(set) var hitTests = 0
        private(set) var effects: [Machine.Effect] = []
        private(set) var dispositions: [Machine.Disposition] = []

        init(_ suite: TestSuite, blocks: Bool = true,
             configure: (inout Machine.Configuration) -> Void = { _ in }) {
            self.suite = suite
            var configuration = Machine.Configuration()
            configuration.blocksEvents = blocks
            configure(&configuration)
            machine = Machine(configuration: configuration)
        }

        var commits: [Action] {
            effects.compactMap { if case let .commit(action) = $0 { return action } else { return nil } }
        }

        var haptics: [Machine.Haptic] {
            effects.compactMap { if case let .haptic(haptic) = $0 { return haptic } else { return nil } }
        }

        /// `.some(nil)` stands for a hidden preview.
        var previews: [Machine.Preview?] {
            effects.compactMap {
                switch $0 {
                case let .showPreview(preview): return .some(preview)
                case .hidePreview: return .some(nil)
                default: return nil
                }
            }
        }

        var lastPreview: Machine.Preview?? { previews.last }

        /// Advances the clock, waking the machine at each of its deadlines.
        mutating func wait(_ duration: TimeInterval) {
            let end = now + duration
            while let deadline = machine.nextDeadline, deadline <= end {
                now = max(now, deadline)
                send(.tick, after: 0)
                // A deadline a punctual wake-up does not move would loop
                // forever: a failure beats a stuck test run.
                if machine.nextDeadline == deadline {
                    suite.expect(false, "deadline \(deadline) is kept by a wake-up on time")
                    break
                }
            }
            now = end
        }

        @discardableResult
        mutating func send(_ event: Machine.Event, after delay: TimeInterval = 0.01) -> Machine.Disposition {
            if delay > 0 { wait(delay) }
            let isOnTarget = onTarget
            var calls = 0
            let output = machine.handle(event, at: now, gridModifierHeld: gridModifierHeld) {
                calls += 1
                return isOnTarget
            }
            hitTests += calls
            effects += output.effects
            if event != .tick { dispositions.append(output.disposition) }
            return output.disposition
        }

        mutating func scroll(_ phase: Machine.Phase, dx: Double = 0, dy: Double = 0) {
            send(.scroll(phase: phase, momentum: nil, dx: dx, dy: dy))
        }

        /// A continuous movement, cut into `changed` events 10 ms apart.
        mutating func move(dx: Double = 0, dy: Double = 0, events: Int = 5) {
            for _ in 0..<events {
                scroll(.changed, dx: dx / Double(events), dy: dy / Double(events))
            }
        }

        mutating func momentum(events: Int = 3) {
            send(.scroll(phase: nil, momentum: .began, dx: 1, dy: 0))
            for _ in 0..<events { send(.scroll(phase: nil, momentum: .changed, dx: 1, dy: 0)) }
            send(.scroll(phase: nil, momentum: .ended, dx: 0, dy: 0))
        }

        /// A whole swipe: down, slide, lift.
        mutating func swipe(dx: Double = 0, dy: Double = 0) {
            scroll(.began)
            move(dx: dx, dy: dy)
            scroll(.ended)
        }

        mutating func pinch(to magnitudes: [Double], phase: Machine.Phase? = nil) {
            for magnitude in magnitudes {
                send(.magnify(cumulative: magnitude, phase: phase))
            }
        }

        /// A whole pinch with phases: pinch in, then lift.
        mutating func pinchIn(to peak: Double = -0.12) {
            send(.magnify(cumulative: -0.01, phase: .began))
            pinch(to: [peak / 2, peak], phase: .changed)
            send(.magnify(cumulative: peak, phase: .ended))
        }
    }

    // MARK: - Sequence table

    private static func sequence(_ suite: TestSuite) {
        func resolves(_ cases: [([Swipe], Action?)], _ label: String) {
            for (steps, action) in cases {
                let resolved = ForkTrackpadGestureSequence.resolve(swipes: steps)
                suite.expect(resolved == action,
                             "\(label): \(steps.map(\.arrow).joined()) gave \(String(describing: resolved))")
            }
        }
        resolves([([.up, .right, .down], .bottomRightQuarter), ([.right, .up, .down], .bottomRightQuarter),
                  ([.left, .up, .down, .up], .topLeftQuarter), ([.up, .up, .right], .topRightQuarter),
                  ([.right, .left, .down], .bottomLeftQuarter)],
                 "the vertical always combines and the latest direction wins")
        resolves([([.up, .right, .left], .topLeftQuarter), ([.right, .up, .left], .topLeftQuarter),
                  ([.down, .left, .right], .bottomRightQuarter), ([.up, .right, .left, .left], .topLeftQuarter)],
                 "reversing the horizontal on a quarter only ever flips the horizontal")
        resolves([([.up, .right, .left, .up], .topLeftQuarter), ([.left, .down, .right, .up], .topRightQuarter),
                  ([.up, .right, .left, .down], .bottomLeftQuarter)],
                 "the vertical keeps up with every later step regardless")
        resolves([([.up, .right, .left, .right], .topRightQuarter)],
                 "an oscillating horizontal keeps flipping without ever touching the vertical")
        resolves([([.left, .up, .down], .bottomLeftQuarter), ([.right, .down, .up], .topRightQuarter)],
                 "reversing the vertical never erases the horizontal")
        resolves([([.left, .up, .down, .down], .bottomHalf), ([.right, .up, .up], .topHalf),
                  ([.left, .up, .down, .down, .down], .bottomHalf), ([.up, .right, .left, .down, .down], .bottomHalf)],
                 "two identical vertical steps in a row force the half")
        resolves([([.up, .up, .right], .topRightQuarter), ([.left, .up, .up, .right], .topRightQuarter),
                  ([.left, .down, .down, .right], .bottomRightQuarter),
                  ([.left, .down, .down, .right, .left], .bottomLeftQuarter)],
                 "the horizontal recombines over a forced half, and a later reversal still only flips it")
        resolves([([.up, .left, .up], .topLeftQuarter), ([.up, .right, .up], .topRightQuarter)],
                 "the vertical pair must be consecutive")
        resolves([([.up, .right, .right], .topRightQuarter), ([.up, .left, .left], .topLeftQuarter)],
                 "a horizontal pair has no special meaning")
        resolves([([.left, .up, .up, .down], .bottomHalf)],
                 "changing one's mind after a forced half lets the latest win")
        resolves([([.down, .right], .bottomRightQuarter), ([.right, .down], .bottomRightQuarter),
                  ([.left, .up], .topLeftQuarter)],
                 "two-step quarters work in either order")
        resolves([([.up, .up], .topHalf), ([.down, .down], .bottomHalf)], "a vertical pair means the half")
        resolves([([.up, .down], .minimize), ([.down, .up], .maximize), ([.left, .right], .rightHalf),
                  ([.right, .left], .leftHalf), ([.left, .left], .leftHalf), ([.up, .up, .up], .topHalf),
                  ([.up, .down, .up], .maximize)],
                 "changing one's mind on a single axis, even repeatedly, always lands on a plain answer")
        resolves([([.upLeft], .topLeftQuarter), ([.upRight], .topRightQuarter),
                  ([.downLeft], .bottomLeftQuarter), ([.downRight], .bottomRightQuarter)],
                 "a diagonal alone is its quarter")
        resolves([([.upRight, .left], .topLeftQuarter), ([.upRight, .right], .topRightQuarter),
                  ([.upRight, .down], .bottomRightQuarter), ([.upRight, .up], .topRightQuarter),
                  ([.upRight, .up, .up], .topHalf), ([.downLeft, .down, .down], .bottomHalf),
                  ([.upRight, .left, .up], .topLeftQuarter)],
                 "after a diagonal the rules of a built quarter apply")
        resolves([([.up, .upRight], .topRightQuarter), ([.down, .upLeft], .topLeftQuarter),
                  ([.up, .up, .downRight], .bottomRightQuarter), ([.up, .left, .downRight], .bottomRightQuarter),
                  ([.upLeft, .downRight], .bottomRightQuarter), ([.left, .right, .upLeft], .topLeftQuarter)],
                 "a diagonal overrides whatever came before")

        suite.expect(ForkTrackpadGestureSequence.resolve(swipes: [.up, .right, .down], on: .dockApp) == nil
                        && ForkTrackpadGestureSequence.resolve(swipes: [.upRight], on: .dockApp) == nil,
                     "swipes do nothing on a Dock icon")
        suite.expect(ForkTrackpadGestureSequence.resolve(pinches: [.in, .in]) == .quitWindowApp
                        && ForkTrackpadGestureSequence.resolve(pinches: [.in, .in], on: .dockApp) == nil
                        && ForkTrackpadGestureSequence.resolve(pinches: [.out, .out]) == nil
                        && ForkTrackpadGestureSequence.resolve(pinches: [.in, .out]) == nil,
                     "pinching in twice quits from a title bar only")
        suite.expect(ForkTrackpadGestureSequence.resolveDoubleTap(on: .titlebar) == .centerReduced
                        && ForkTrackpadGestureSequence.resolveDoubleTap(on: .dockApp) == nil,
                     "a double tap centers from a title bar only")
    }

    // MARK: - Catalog

    private static func catalog(_ suite: TestSuite) {
        for entry in ForkTrackpadGestureCatalog.entries {
            for target in entry.targets {
            for trigger in entry.triggers {
                let resolved: Action?
                switch trigger {
                case let .swipes(steps):
                    resolved = ForkTrackpadGestureSequence.resolve(swipes: steps, on: target)
                case let .pinches(steps):
                    resolved = ForkTrackpadGestureSequence.resolve(pinches: steps, on: target)
                case .doubleTap:
                    resolved = ForkTrackpadGestureSequence.resolveDoubleTap(on: target)
                }
                suite.expect(resolved == entry.action,
                             "catalog trigger \(trigger) on \(target) resolves to \(entry.action)")
            }
            }
        }

        // A held modifier's actions reach only through another action's own
        // catalog entry (see ForkTrackpadModifierRemap): they have no trigger
        // or card of their own, so the catalog never lists them.
        let modifierReachActions: Set<Action> = [.minimizeAllWindows, .marginMaximize,
                                                  .moveToPreviousDisplay, .moveToNextDisplay, .restorePlacement,
                                                  .leftThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
                                                  .topLeftSixth, .topRightSixth,
                                                  .bottomLeftSixth, .bottomRightSixth,
                                                  .topCenterSixth, .bottomCenterSixth,
                                                  .topLeftTwoSixths, .topRightTwoSixths,
                                                  .bottomLeftTwoSixths, .bottomRightTwoSixths,
                                                  .centerThird]
        let listed = ForkTrackpadGestureCatalog.entries.map(\.action)
        suite.expect(listed.count == Set(listed).count
                        && Set(listed) == Set(Action.allCases).subtracting(modifierReachActions),
                     "every gesture action is listed exactly once in the catalog, bar a held modifier's own")

        let diagonals: [Action: Swipe] = [.topLeftQuarter: .upLeft, .topRightQuarter: .upRight,
                                          .bottomLeftQuarter: .downLeft, .bottomRightQuarter: .downRight]
        for (action, diagonal) in diagonals {
            let triggers = ForkTrackpadGestureCatalog.entry(for: action)?.triggers ?? []
            suite.expect(triggers.count == 3 && triggers.first == .swipes([diagonal]),
                         "\(action) lists its diagonal first, then both orders")
        }

        suite.expect(Action.leftHalf.rawValue == "leftHalf" && Action.quitApp.rawValue == "quitApp"
                        && Action(rawValue: "bottomRightQuarter") == .bottomRightQuarter,
                     "gesture raw values stay stable preference identifiers")

        let placements: [Action: WindowLayoutAction] = [
            .leftHalf: .leftHalf, .rightHalf: .rightHalf, .topHalf: .topHalf, .bottomHalf: .bottomHalf,
            .topLeftQuarter: .topLeft, .topRightQuarter: .topRight,
            .bottomLeftQuarter: .bottomLeft, .bottomRightQuarter: .bottomRight,
            .maximize: .maximize, .toggleFullScreen: .fullScreen,
            .marginMaximize: .marginMaximize,
            .moveToPreviousDisplay: .previousDisplay, .moveToNextDisplay: .nextDisplay,
            .leftThird: .leftThird, .rightThird: .rightThird,
            .leftTwoThirds: .leftTwoThirds, .rightTwoThirds: .rightTwoThirds,
            .centerThird: .centerThird,
            .topLeftSixth: .topLeftSixth, .topRightSixth: .topRightSixth,
            .bottomLeftSixth: .bottomLeftSixth, .bottomRightSixth: .bottomRightSixth,
            .topCenterSixth: .topCenterSixth, .bottomCenterSixth: .bottomCenterSixth,
        ]
        for action in Action.allCases {
            suite.expect(action.layoutAction == placements[action],
                         "\(action) uses the window layout placement \(String(describing: placements[action]))")
        }

        suite.expect(ForkTrackpadGestureSequence.accepts(.swipe, on: .titlebar)
                        && ForkTrackpadGestureSequence.accepts(.pinch, on: .titlebar)
                        && ForkTrackpadGestureSequence.accepts(.pinch, on: .dockApp)
                        && ForkTrackpadGestureSequence.accepts(.swipe, on: .dockApp)
                        && !ForkTrackpadGestureSequence.accepts(.tap, on: .dockApp)
                        && !ForkTrackpadGestureSequence.accepts(.swipe, on: .dockTrash),
                     "title bars take every gesture, app icons swipes and pinches, the Trash pinches only")
        suite.expect(!ForkTrackpadGestureSequence.accepts(.pinch, on: .dockApp, disabled: [.quitApp])
                        && ForkTrackpadGestureSequence.accepts(.pinch, on: .titlebar, disabled: [.quitApp]),
                     "disabling the only Dock gesture releases the Dock")
        let allSwipesButOne = Set(ForkTrackpadGestureCatalog.entries.filter { $0.family == .swipe }.map(\.action))
            .subtracting([.bottomRightQuarter])
        suite.expect(ForkTrackpadGestureSequence.accepts(.swipe, on: .titlebar, disabled: allSwipesButOne)
                        && !ForkTrackpadGestureSequence.accepts(.swipe, on: .titlebar,
                                                                   disabled: allSwipesButOne.union([.bottomRightQuarter])),
                     "one remaining gesture keeps its family captured")
    }

    // MARK: - Title bar

    private static func titlebar(_ suite: TestSuite) {
        // An 800 × 600 window whose top sits at y = 50, in Accessibility
        // coordinates. The paths are typical shapes, element hit first.
        let frame = CGRect(x: 100, y: 50, width: 800, height: 600)
        let standard = ForkTrackpadAXNode(role: "AXWindow", subrole: "AXStandardWindow")
        func node(_ role: String, _ subrole: String? = nil) -> ForkTrackpadAXNode {
            ForkTrackpadAXNode(role: role, subrole: subrole)
        }
        func verdict(_ path: [ForkTrackpadAXNode], window: ForkTrackpadAXNode? = nil,
                     y: CGFloat, x: CGFloat = 400, band: Double = 40) -> ForkTrackpadTitlebar.Verdict {
            ForkTrackpadTitlebar.evaluate(path: path, window: window ?? standard, windowFrame: frame,
                                            point: CGPoint(x: x, y: y), bandHeight: band)
        }

        suite.expect(verdict([], y: 60) == .titlebar, "a native title bar is the window itself near its top")
        suite.expect(verdict([], y: 200) == .outsideBand, "the window background below the band is not a title bar")
        suite.expect(verdict([node("AXButton"), node("AXGroup"), node("AXToolbar")], y: 85) == .titlebar,
                     "a toolbar counts even below the band")
        let tabs = [node("AXRadioButton", "AXTabButton"), node("AXTabGroup"), node("AXGroup")]
        suite.expect(verdict(tabs, y: 70) == .titlebar && verdict(tabs, y: 120) == .outsideBand,
                     "a hand-drawn tab strip falls back on the band")
        suite.expect(verdict([], y: 90) == .titlebar && verdict([], y: 91) == .outsideBand
                        && verdict([], y: 140, band: 100) == .titlebar,
                     "the band boundary is inclusive and follows the setting")
        suite.expect(verdict([], y: 60, x: 950) == .outsideBand,
                     "a point outside the window width is not a title bar")

        suite.expect(verdict([node("AXTextField"), node("AXGroup"), node("AXToolbar")], y: 60)
                        == .excludedElement(role: "AXTextField"),
                     "an address field inside a toolbar stays with the app")
        suite.expect(verdict([node("AXGroup"), node("AXWebArea"), node("AXScrollArea"), node("AXGroup")], y: 60)
                        == .excludedElement(role: "AXWebArea"),
                     "web content near the top stays with the app")
        suite.expect(verdict([node("AXRadioButton"), node("AXTabGroup"), node("AXScrollArea")], y: 60)
                        == .excludedElement(role: "AXScrollArea"),
                     "a scrolling tab strip stays with the app")
        suite.expect(verdict([node("AXSlider"), node("AXToolbar")], y: 60) == .excludedElement(role: "AXSlider"),
                     "a slider inside a toolbar stays with the app")
        suite.expect(verdict([node("AXButton"), node("AXPopover")], y: 60) == .excludedElement(role: "AXPopover"),
                     "a popover stays with the app")

        let floating = ForkTrackpadAXNode(role: "AXWindow", subrole: "AXFloatingWindow")
        suite.expect(verdict([], window: floating, y: 60) == .unsupportedWindow(subrole: "AXFloatingWindow"),
                     "floating panels are not targets")
        suite.expect(verdict([], window: ForkTrackpadAXNode(role: "AXWindow", subrole: "AXDialog"), y: 60) == .titlebar
                        && verdict([], window: ForkTrackpadAXNode(role: "AXWindow"), y: 60) == .titlebar,
                     "dialogs and windows without a subrole are targets")
    }

    // MARK: - One swipe, one action, on the lift

    private static func swipes(_ suite: TestSuite) {
        for (dx, dy, action) in [(-40.0, 0.0, Action.leftHalf), (40, 0, .rightHalf),
                                 (0, -40, .maximize), (0, 40, .minimize)] {
            var driver = Driver(suite)
            driver.swipe(dx: dx, dy: dy)
            suite.expect(driver.commits == [action], "a simple swipe dx=\(dx) dy=\(dy) gives \(action)")
        }

        var lift = Driver(suite)
        lift.scroll(.began)
        lift.move(dx: -40)
        suite.expect(lift.commits.isEmpty && lift.lastPreview == .some(.action(.leftHalf)),
                     "nothing fires while the fingers are down, but the preview already shows the target")
        lift.scroll(.ended)
        suite.expect(lift.commits == [.leftHalf] && lift.lastPreview == .some(nil),
                     "the action fires on the lift and the preview disappears")

        var below = Driver(suite)
        below.swipe(dx: -4)
        suite.expect(below.commits.isEmpty && below.previews.isEmpty,
                     "below the threshold, neither action nor preview")

        var atThreshold = Driver(suite)
        atThreshold.swipe(dx: -5)
        suite.expect(atThreshold.commits == [.leftHalf], "the default swipe threshold is reached at 5")
        var weakPinch = Driver(suite)
        weakPinch.pinch(to: [0.01, 0.017])
        weakPinch.wait(0.2)
        var pinch = Driver(suite)
        pinch.pinch(to: [0.01, 0.023])
        pinch.wait(0.2)
        suite.expect(weakPinch.commits.isEmpty && pinch.commits == [.toggleFullScreen],
                     "the default pinch threshold sits between 0.017 and 0.023")

        var quarter = Driver(suite)
        quarter.scroll(.began)
        quarter.move(dy: 40)
        suite.expect(quarter.lastPreview == .some(.action(.minimize)), "↓ previews minimize")
        quarter.wait(0.35)
        suite.expect(quarter.haptics == [.step], "a pause validates the ↓ step")
        quarter.move(dx: 40)
        suite.expect(quarter.lastPreview == .some(.action(.bottomRightQuarter)), "↓ then → previews the quarter")
        quarter.scroll(.ended)
        suite.expect(quarter.commits == [.bottomRightQuarter], "↓, pause, → snaps to the bottom right quarter")

        var rightThenDown = Driver(suite)
        rightThenDown.scroll(.began)
        rightThenDown.move(dx: 40)
        rightThenDown.wait(0.35)
        rightThenDown.move(dy: 40)
        rightThenDown.scroll(.ended)
        var upThenLeft = Driver(suite)
        upThenLeft.scroll(.began)
        upThenLeft.move(dy: -40)
        upThenLeft.wait(0.35)
        upThenLeft.move(dx: -40)
        upThenLeft.scroll(.ended)
        suite.expect(rightThenDown.commits == [.bottomRightQuarter] && upThenLeft.commits == [.topLeftQuarter],
                     "quarters work in both orders")

        for (dy, action) in [(-40.0, Action.topHalf), (40, .bottomHalf)] {
            var driver = Driver(suite)
            driver.scroll(.began)
            driver.move(dy: dy)
            driver.wait(0.35)
            driver.move(dy: dy)
            driver.scroll(.ended)
            suite.expect(driver.commits == [action], "a double vertical swipe snaps to \(action)")
        }

        // Down then right in one movement: one step, read on the total
        // (60, 30), about 27°, too flat for a diagonal.
        var oneStep = Driver(suite)
        oneStep.scroll(.began)
        oneStep.move(dy: 30)
        oneStep.move(dx: 60)
        oneStep.scroll(.ended)
        suite.expect(oneStep.commits == [.rightHalf] && oneStep.haptics.isEmpty,
                     "without a pause the gesture stays one step on its dominant direction")
    }

    // MARK: - Diagonals

    private static func diagonals(_ suite: TestSuite) {
        for (dx, dy, action) in [(-40.0, -40.0, Action.topLeftQuarter), (40, -40, .topRightQuarter),
                                 (-40, 40, .bottomLeftQuarter), (40, 40, .bottomRightQuarter)] {
            var driver = Driver(suite)
            driver.scroll(.began)
            driver.move(dx: dx, dy: dy)
            let previewed = driver.lastPreview == .some(.action(action))
            driver.scroll(.ended)
            suite.expect(previewed && driver.commits == [action] && driver.haptics.isEmpty,
                         "a diagonal dx=\(dx) dy=\(dy) snaps to \(action) without a pause")
        }

        func commits(dx: Double, dy: Double) -> [Action] {
            var driver = Driver(suite)
            driver.swipe(dx: dx, dy: dy)
            return driver.commits
        }
        suite.expect(commits(dx: 40, dy: -22) == [.rightHalf], "29° is still a half")
        suite.expect(commits(dx: 40, dy: -24) == [.topRightQuarter], "31° is a diagonal")
        suite.expect(commits(dx: 22, dy: -40) == [.maximize], "61° is still ↑")
        suite.expect(commits(dx: 24, dy: -40) == [.topRightQuarter], "59° is a diagonal")

        var off = Driver(suite) { $0.diagonalRatio = 1.01 }
        off.swipe(dx: 40, dy: 39)
        suite.expect(off.commits == [.rightHalf], "diagonals can be turned off")

        var thenLeft = Driver(suite)
        thenLeft.scroll(.began)
        thenLeft.move(dx: 40, dy: -40)
        thenLeft.wait(0.35)
        let stepped = thenLeft.haptics == [.step]
        thenLeft.move(dx: -40)
        let previewed = thenLeft.lastPreview == .some(.action(.topLeftQuarter))
        thenLeft.scroll(.ended)
        suite.expect(stepped && previewed && thenLeft.commits == [.topLeftQuarter]
                        && thenLeft.haptics == [.step, .step],
                     "a diagonal step then reversing the horizontal flips straight across, "
                        + "ticking again without a pause")

        var disabled = Driver(suite) { $0.disabledActions = [.topRightQuarter] }
        disabled.scroll(.began)
        disabled.move(dx: 40, dy: -40)
        let unrecognized = disabled.lastPreview == .some(.unrecognized)
        disabled.scroll(.ended)
        suite.expect(unrecognized && disabled.commits.isEmpty, "a disabled quarter disables its diagonal")

        var repeatedLeft = Driver(suite)
        repeatedLeft.scroll(.began)
        repeatedLeft.move(dx: -40)
        repeatedLeft.wait(0.35)
        repeatedLeft.move(dx: -40)
        let stillLeftHalf = repeatedLeft.lastPreview == .some(.action(.leftHalf))
        repeatedLeft.scroll(.ended)
        suite.expect(stillLeftHalf && repeatedLeft.commits == [.leftHalf],
                     "repeating the same half keeps affirming it, never a question mark for its own sake")

        // Letting go of both axes at once (easing back toward where the
        // gesture started) is the one way left to hold nothing at all once
        // combined: the preview holds what it last showed instead of
        // blanking, and the lift does nothing since nothing is held.
        var bothRelease = Driver(suite)
        bothRelease.scroll(.began)
        bothRelease.move(dy: -40)
        bothRelease.wait(0.35)
        bothRelease.move(dx: 40)
        bothRelease.wait(0.35)
        let formedTopRight = bothRelease.lastPreview == .some(.action(.topRightQuarter))
        bothRelease.move(dx: -3, dy: 3)
        let stillShowsTopRight = bothRelease.lastPreview == .some(.action(.topRightQuarter))
        bothRelease.scroll(.ended)
        suite.expect(formedTopRight && stillShowsTopRight && bothRelease.commits.isEmpty,
                     "easing both axes back to the middle at once holds the last preview rather than "
                        + "blanking it, and the lift does nothing since nothing is actually held any more")
    }

    // MARK: - Cancellation

    private static func cancellation(_ suite: TestSuite) {
        var still = Driver(suite)
        still.scroll(.began)
        still.move(dx: -40)
        still.wait(0.9)
        suite.expect(still.effects.contains(.cancelled(.stillness)) && still.lastPreview == .some(nil),
                     "staying still cancels and hides the preview")
        still.move(dx: 40)
        still.scroll(.ended)
        suite.expect(still.commits.isEmpty, "a cancelled gesture does nothing, even when moving again")

        var stepThenStill = Driver(suite)
        stepThenStill.scroll(.began)
        stepThenStill.move(dy: 40)
        stepThenStill.wait(0.35)
        stepThenStill.wait(0.5)
        stepThenStill.scroll(.ended)
        suite.expect(stepThenStill.haptics == [.step, .cancel] && stepThenStill.commits.isEmpty,
                     "a pause validates a step, then longer stillness cancels")

        var escape = Driver(suite)
        escape.scroll(.began)
        escape.move(dx: 40)
        let escapeDisposition = escape.send(.escape)
        escape.scroll(.ended)
        suite.expect(escapeDisposition == .swallow && escape.commits.isEmpty
                        && escape.effects.contains(.cancelled(.escape)),
                     "Escape cancels a gesture and does not reach the app")

        var interrupted = Driver(suite)
        interrupted.scroll(.began)
        interrupted.move(dx: 40)
        interrupted.scroll(.cancelled)
        suite.expect(interrupted.effects.contains(.cancelled(.interrupted)),
                     "a system interruption is reported as such")

        // A long first movement (1 s) does not use up the delay: stillness
        // counts from the last movement.
        var long = Driver(suite)
        long.scroll(.began)
        long.move(dx: -40, events: 100)
        long.wait(0.35)
        long.wait(0.4)
        long.move(dy: 40)
        long.scroll(.ended)
        suite.expect(long.commits == [.bottomLeftQuarter],
                     "stillness is counted from the last movement, not from the gesture start")

        var flat = Driver(suite)
        flat.scroll(.began)
        flat.move(dx: -40)
        flat.wait(0.35)
        for _ in 0..<60 { flat.scroll(.changed, dx: 0, dy: 0) }
        suite.expect(flat.effects.contains(.cancelled(.stillness)),
                     "changed events without movement do not count as movement")

        var idleEscape = Driver(suite)
        suite.expect(idleEscape.send(.escape) == .pass, "Escape outside a gesture passes")

        var resting = Driver(suite)
        resting.scroll(.mayBegin)
        resting.scroll(.cancelled)
        suite.expect(resting.effects.isEmpty, "resting fingers then lifting is not a failed gesture")
    }

    // MARK: - What is swallowed, and when

    private static func dispositions(_ suite: TestSuite) {
        var captured = Driver(suite, blocks: true)
        captured.swipe(dx: 40)
        captured.momentum()
        suite.expect(Set(captured.dispositions) == [.swallow],
                     "a captured gesture is swallowed as a whole, momentum included")

        var armed = Driver(suite)
        armed.scroll(.mayBegin)
        armed.scroll(.began)
        armed.move(dx: 40)
        armed.scroll(.ended)
        suite.expect(armed.commits == [.rightHalf] && armed.hitTests == 1 && Set(armed.dispositions) == [.swallow],
                     "mayBegin arms the same gesture with a single hit test")

        var offTarget = Driver(suite)
        offTarget.onTarget = nil
        offTarget.swipe(dx: 40)
        offTarget.momentum()
        suite.expect(Set(offTarget.dispositions) == [.pass] && offTarget.effects.isEmpty && offTarget.hitTests == 1,
                     "an off-target gesture passes entirely after one hit test")

        var listenOnly = Driver(suite, blocks: false)
        listenOnly.swipe(dx: 40)
        listenOnly.momentum()
        suite.expect(Set(listenOnly.dispositions) == [.pass] && listenOnly.commits == [.rightHalf],
                     "the non-blocking mode follows gestures but lets everything pass")

        var wheel = Driver(suite)
        wheel.send(.scroll(phase: nil, momentum: nil, dx: 0, dy: 40))
        suite.expect(wheel.dispositions == [.pass] && wheel.hitTests == 0, "a mouse wheel is never a gesture")

        var loose = Driver(suite)
        loose.momentum()
        suite.expect(Set(loose.dispositions) == [.pass], "the momentum of an uncaptured scroll passes")

        var disabled = Driver(suite) { $0.swipeEnabled = false }
        disabled.swipe(dx: 40)
        suite.expect(disabled.commits.isEmpty && disabled.hitTests == 0 && Set(disabled.dispositions) == [.pass],
                     "disabled swipes skip the hit test")
    }

    // MARK: - Pinch

    private static func pinches(_ suite: TestSuite) {
        var out = Driver(suite)
        out.pinch(to: [0.02, 0.06, 0.12, 0.15])
        let beforeLift = out.commits.isEmpty
        out.wait(0.2)
        suite.expect(beforeLift && out.commits == [.toggleFullScreen],
                     "pinching out toggles full screen after the silence")

        var inward = Driver(suite)
        inward.pinch(to: [-0.03, -0.08, -0.14])
        inward.wait(0.6)
        suite.expect(inward.commits == [.close], "pinching in closes the window")

        var peak = Driver(suite)
        // Relaxing brings the last value under the threshold before the lift.
        peak.pinch(to: [0.05, 0.12, 0.05, 0.01])
        peak.wait(0.2)
        suite.expect(peak.commits == [.toggleFullScreen], "a pinch decides on its peak, not its last value")

        var noChain = Driver(suite)
        noChain.pinch(to: [-0.05, -0.12], phase: .changed)
        noChain.wait(0.35)
        let noStep = noChain.haptics.isEmpty
        noChain.pinch(to: [-0.08, -0.05], phase: .changed)
        let stillClose = noChain.lastPreview == .some(.action(.close))
        noChain.send(.magnify(cumulative: -0.05, phase: .ended))
        noChain.wait(0.5)
        suite.expect(noStep && stillClose && noChain.commits == [.close],
                     "a pinch never chains steps, even with a pause")

        var silence = Driver(suite)
        silence.pinch(to: [-0.05, -0.12])
        silence.wait(0.15 + 0.39)
        let waiting = silence.commits.isEmpty
        silence.wait(0.02)
        suite.expect(waiting && silence.commits == [.close],
                     "a pinch without phase ends on the silence, then waits for a second one")

        var offTarget = Driver(suite)
        offTarget.onTarget = nil
        offTarget.pinch(to: [0.05, 0.1, 0.15, 0.2])
        offTarget.wait(0.2)
        suite.expect(Set(offTarget.dispositions) == [.pass] && offTarget.hitTests == 1 && offTarget.commits.isEmpty,
                     "an off-target pinch passes and is checked once")
        offTarget.onTarget = .titlebar
        offTarget.pinch(to: [0.05, 0.15])
        offTarget.wait(0.2)
        suite.expect(offTarget.hitTests == 2 && offTarget.commits == [.toggleFullScreen],
                     "the next pinch is checked again")

        // A host that sent no tick: the next pinch, after the silence, ends
        // the previous one before starting.
        var late = Driver(suite)
        late.pinch(to: [0.05, 0.15])
        late.now += 0.5
        late.send(.magnify(cumulative: -0.05, phase: nil), after: 0)
        late.pinch(to: [-0.15])
        late.wait(0.6)
        suite.expect(late.commits == [.toggleFullScreen, .close], "a late host still separates two pinches")
    }

    // MARK: - Pinching in twice

    private static func doublePinch(_ suite: TestSuite) {
        var twice = Driver(suite)
        twice.pinchIn()
        suite.expect(twice.commits.isEmpty && twice.lastPreview == .some(.action(.close)),
                     "closing waits for a possible second pinch, preview shown")
        twice.wait(0.3)
        twice.pinchIn()
        suite.expect(twice.previews.dropLast().last == .some(.action(.quitWindowApp))
                        && twice.commits == [.quitWindowApp] && twice.hitTests == 1,
                     "pinching in twice quits the app of the same window, without closing first")
        twice.wait(1)
        suite.expect(twice.commits == [.quitWindowApp], "nothing else fires after quitting")

        var exact = Driver(suite)
        exact.pinchIn()
        exact.wait(0.39)
        let notYet = exact.commits.isEmpty
        exact.wait(0.02)
        suite.expect(notYet && exact.commits == [.close] && exact.lastPreview == .some(nil),
                     "closing waits exactly the double-pinch interval")

        var setting = Driver(suite) { $0.doublePinchInterval = 0.2 }
        setting.pinchIn()
        setting.wait(0.21)
        suite.expect(setting.commits == [.close], "the double-pinch interval is a setting")

        var tooLate = Driver(suite)
        tooLate.pinchIn()
        tooLate.wait(0.5)
        tooLate.pinchIn()
        tooLate.wait(0.5)
        suite.expect(tooLate.commits == [.close, .close] && tooLate.hitTests == 2,
                     "a second pinch too late is a new gesture")

        var spreads = Driver(suite)
        spreads.pinchIn()
        spreads.wait(0.2)
        spreads.send(.magnify(cumulative: 0.01, phase: .began))
        spreads.pinch(to: [0.08, 0.15], phase: .changed)
        let showsClose = spreads.lastPreview == .some(.action(.close))
        spreads.send(.magnify(cumulative: 0.15, phase: .ended))
        suite.expect(showsClose && spreads.commits == [.close], "a second pinch that spreads still closes")

        var quitOff = Driver(suite) { $0.disabledActions = [.quitWindowApp] }
        quitOff.pinchIn()
        suite.expect(quitOff.commits == [.close], "with quitting off, closing is immediate")

        var closeOff = Driver(suite) { $0.disabledActions = [.close] }
        closeOff.pinchIn()
        closeOff.wait(0.2)
        closeOff.pinchIn()
        var once = Driver(suite) { $0.disabledActions = [.close] }
        once.pinchIn()
        once.wait(1)
        suite.expect(closeOff.commits == [.quitWindowApp] && once.commits.isEmpty,
                     "with closing off, pinching in twice still quits and once does nothing")

        var swipeDuringWait = Driver(suite)
        swipeDuringWait.pinchIn()
        swipeDuringWait.wait(0.1)
        swipeDuringWait.scroll(.began)
        suite.expect(swipeDuringWait.commits == [.close] && swipeDuringWait.dispositions.last == .pass
                        && swipeDuringWait.hitTests == 1,
                     "a swipe during the wait closes first and is not followed")

        var lateHost = Driver(suite)
        lateHost.pinchIn()
        lateHost.now += 0.5
        lateHost.send(.magnify(cumulative: -0.01, phase: .began), after: 0)
        suite.expect(lateHost.commits == [.close] && lateHost.hitTests == 2,
                     "a host woken late settles the wait before the next pinch")

        var dock = Driver(suite)
        dock.onTarget = .dockApp
        dock.pinchIn()
        suite.expect(dock.commits == [.quitApp], "pinching in on a Dock icon quits at once, with no double to wait for")
    }

    // MARK: - Double tap

    private static func doubleTap(_ suite: TestSuite) {
        var tap = Driver(suite)
        tap.send(.smartMagnify)
        suite.expect(tap.commits == [.centerReduced] && tap.hitTests == 1, "a double tap centers the window")

        var off = Driver(suite)
        off.onTarget = nil
        off.send(.smartMagnify)
        var dock = Driver(suite)
        dock.onTarget = .dockApp
        dock.send(.smartMagnify)
        suite.expect(off.commits.isEmpty && off.dispositions == [.pass] && dock.commits.isEmpty,
                     "a double tap elsewhere stays with the app")

        var disabled = Driver(suite) { $0.disabledActions = [.centerReduced] }
        disabled.send(.smartMagnify)
        suite.expect(disabled.commits.isEmpty && disabled.hitTests == 0, "a disabled double tap skips the hit test")

        var during = Driver(suite)
        during.scroll(.began)
        during.send(.smartMagnify)
        suite.expect(during.commits.isEmpty && during.hitTests == 1, "a double tap during a gesture is ignored")

        var waiting = Driver(suite)
        waiting.pinchIn()
        waiting.send(.smartMagnify)
        suite.expect(waiting.commits == [.close], "a double tap during the double-pinch wait closes instead")
    }

    // MARK: - Dock icon

    private static func dock(_ suite: TestSuite) {
        var quit = Driver(suite)
        quit.onTarget = .dockApp
        quit.pinch(to: [-0.03, -0.08, -0.14])
        let previewed = quit.lastPreview == .some(.action(.quitApp))
        quit.wait(0.2)
        suite.expect(previewed && quit.commits == [.quitApp], "pinching in on a Dock icon quits the app")

        var out = Driver(suite)
        out.onTarget = .dockApp
        out.pinch(to: [0.05, 0.15])
        let unrecognized = out.lastPreview == .some(.unrecognized)
        out.wait(0.2)
        suite.expect(unrecognized && out.commits.isEmpty, "pinching out on a Dock icon does nothing yet")

        var next = Driver(suite, blocks: false)
        next.onTarget = .dockApp
        next.swipe(dx: 40)
        next.momentum()
        next.wait(0.2)
        suite.expect(next.commits == [.showNextWindow] && Set(next.dispositions) == [.pass],
                     "a rightward swipe on a Dock icon chains to its next window")
        var previous = Driver(suite, blocks: false)
        previous.onTarget = .dockApp
        previous.swipe(dx: -40)
        previous.momentum()
        previous.wait(0.2)
        suite.expect(previous.commits == [.showPreviousWindow],
                     "a leftward swipe chains to the previous one")
        var upUp = Driver(suite, blocks: false)
        upUp.onTarget = .dockApp
        upUp.scroll(.began)
        upUp.move(dy: -40)
        upUp.wait(0.16)
        upUp.move(dy: -40)
        upUp.scroll(.ended)
        upUp.momentum()
        upUp.wait(0.2)
        suite.expect(upUp.commits.isEmpty && Set(upUp.dispositions) == [.pass],
                     "a sequence a Dock icon has no action for does nothing and is left to the Dock")
        var trash = Driver(suite, blocks: true)
        trash.onTarget = .dockTrash
        trash.swipe(dy: 40)
        trash.momentum()
        suite.expect(trash.commits.isEmpty && trash.effects.isEmpty && Set(trash.dispositions) == [.pass],
                     "a swipe on the Trash is left to the Dock")
        let service = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadGestureService.swift")
        suite.expect(service.contains("if preview == .unrecognized, !isOnWindow {\n            ForkTrackpadGesturePreview.shared.hide()\n            return\n        }"),
                     "on the Dock, a gesture that means nothing shows no question mark")

        var titlebar = Driver(suite)
        titlebar.pinch(to: [-0.05, -0.14])
        titlebar.wait(0.6)
        suite.expect(titlebar.commits == [.close], "on a title bar, pinching in closes the window rather than quitting")
    }

    private static func dockIcon(_ suite: TestSuite) {
        typealias Dock = ForkTrackpadDock
        typealias App = ForkTrackpadRunningApp
        let own: pid_t = 1
        let icon = ForkTrackpadAXNode(role: "AXDockItem", subrole: "AXApplicationDockItem")
        let textEdit = App(pid: 42, bundleURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                           bundleIdentifier: "com.apple.TextEdit")
        let safari = App(pid: 43, bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
                         bundleIdentifier: "com.apple.Safari")
        let running = [textEdit, safari]
        func verdict(_ item: ForkTrackpadAXNode = icon, running isRunning: Bool = true,
                     url: String?, identifier: String? = nil,
                     apps: [App] = running) -> Dock.Verdict {
            Dock.evaluate(item: item, isRunning: isRunning, itemURL: url.map(URL.init(fileURLWithPath:)),
                          itemBundleIdentifier: identifier, runningApps: apps, ownPID: own)
        }

        suite.expect(verdict(url: "/Applications/Safari.app") == .app(safari),
                     "a running app's Dock icon names that app")
        suite.expect(verdict(url: "/Applications/TextEdit.app", identifier: "com.apple.TextEdit") == .app(textEdit),
                     "a Dock icon whose path differs falls back on the bundle identifier")
        suite.expect(verdict(running: false, url: "/Applications/Safari.app") == .notRunning,
                     "the kept icon of an app that is not running is not a target")
        suite.expect(verdict(url: "/Applications/Notes.app") == .notRunning,
                     "an icon whose app cannot be found is not a target")
        let folder = ForkTrackpadAXNode(role: "AXDockItem", subrole: "AXFolderDockItem")
        let trash = ForkTrackpadAXNode(role: "AXDockItem", subrole: "AXTrashDockItem")
        let list = ForkTrackpadAXNode(role: "AXList")
        suite.expect(verdict(folder, url: "/Applications/Safari.app") == .notAnAppItem(subrole: "AXFolderDockItem")
                        && verdict(list, url: "/Applications/Safari.app") == .notAnAppItem(subrole: nil),
                     "folders and anything but an app icon or the Trash are not targets")
        suite.expect(verdict(trash, url: nil) == .trash
                        && verdict(trash, running: false, url: "/Applications/Safari.app") == .trash
                        && verdict(ForkTrackpadAXNode(role: "AXList", subrole: "AXTrashDockItem"), url: nil)
                        == .notAnAppItem(subrole: "AXTrashDockItem"),
                     "the Trash's Dock item is a target of its own, and only as a Dock item")

        let ownApp = App(pid: own, bundleURL: URL(fileURLWithPath: "/Applications/Vorssaint.app"),
                         bundleIdentifier: "com.vorssaint.utils")
        suite.expect(verdict(url: "/Applications/Vorssaint.app", apps: running + [ownApp]) == .ownApp,
                     "a pinch on this app's own Dock icon never quits it")
        let finder = App(pid: 50, bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                         bundleIdentifier: "com.apple.finder")
        suite.expect(verdict(url: "/System/Library/CoreServices/Finder.app", apps: running + [finder])
                        == .finder(finder)
                        && ForkTrackpadGestureSequence.resolve(pinches: [.in], on: .dockFinder) == nil
                        && !ForkTrackpadGestureSequence.accepts(.pinch, on: .dockFinder)
                        && ForkTrackpadDock.protectedBundleIdentifiers.contains("com.apple.finder"),
                     "the Finder, which the Dock offers no Quit for, is protected: no pinch on its icon")

        let copy = App(pid: 44, bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
                       bundleIdentifier: "com.apple.Safari")
        let twin = App(pid: 45, bundleURL: URL(fileURLWithPath: "/Users/me/Safari.app"),
                       bundleIdentifier: "com.apple.Safari")
        suite.expect(verdict(url: "/Applications/Safari.app", apps: [safari, copy]) == .notRunning
                        && verdict(url: "/Applications/Other.app", identifier: "com.apple.Safari",
                                   apps: [safari, twin]) == .notRunning,
                     "two candidate apps for one icon quit neither")
        suite.expect(verdict(url: "/Applications/Safari.app", identifier: "com.apple.Safari",
                             apps: [safari, twin]) == .app(safari),
                     "the icon's path tells two copies of one app apart")
    }

    private static func dockItemIndex(_ suite: TestSuite) {
        typealias Dock = ForkTrackpadDock
        // A bottom Dock, its frames shifted 72 pt on the short axis as
        // macOS 27 reports them.
        let bottom = CGRect(x: 400, y: 760, width: 300, height: 60)
        let icons: [CGRect?] = [CGRect(x: 400, y: 760, width: 60, height: 60),
                                nil,
                                CGRect(x: 520, y: 760, width: 60, height: 60)]
        suite.expect(Dock.itemIndex(at: CGPoint(x: 430, y: 850), itemFrames: icons, listFrame: bottom) == 0
                        && Dock.itemIndex(at: CGPoint(x: 540, y: 850), itemFrames: icons, listFrame: bottom) == 2,
                     "a bottom Dock's icon is found along its long axis, whatever the short axis says")
        suite.expect(Dock.itemIndex(at: CGPoint(x: 490, y: 850), itemFrames: icons, listFrame: bottom) == nil
                        && Dock.itemIndex(at: CGPoint(x: 800, y: 850), itemFrames: icons, listFrame: bottom) == nil,
                     "an icon without a frame, or past the last one, is not found")
        suite.expect(Dock.itemIndex(at: CGPoint(x: 460, y: 850), itemFrames: icons, listFrame: bottom) == nil,
                     "an icon's far edge belongs to the next one")

        let side = CGRect(x: 0, y: 200, width: 60, height: 300)
        let sideIcons: [CGRect?] = [CGRect(x: 0, y: 200, width: 60, height: 60),
                                    CGRect(x: 0, y: 260, width: 60, height: 60)]
        suite.expect(Dock.itemIndex(at: CGPoint(x: 90, y: 270), itemFrames: sideIcons, listFrame: side) == 1,
                     "a Dock on the side is read along its height")
    }

    private static func previewContent(_ suite: TestSuite) {
        typealias Content = ForkTrackpadPreviewContent
        func content(_ action: Action) -> Content { Content(.action(action)) }
        suite.expect(content(.leftHalf) == .zone(CGRect(x: 0, y: 0, width: 0.5, height: 1))
                        && content(.rightHalf) == .zone(CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
                        && content(.maximize) == .zone(CGRect(x: 0, y: 0, width: 1, height: 1)),
                     "halves and fill preview the zone the placement will use")
        suite.expect(content(.topHalf) == .zone(CGRect(x: 0, y: 0, width: 1, height: 0.5))
                        && content(.bottomHalf) == .zone(CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
                        && content(.topRightQuarter) == .zone(CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
                        && content(.bottomLeftQuarter) == .zone(CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),
                     "the preview's zones have their origin at the top, like the screen they draw")
        suite.expect(content(.centerReduced) == .zone(CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
                        && Content(.action(.centerReduced), centerScale: 0.8)
                            == .zone(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)),
                     "the double tap previews the centered size")
        suite.expect(content(.close) == .light(.close)
                        && content(.minimize) == .light(.minimize)
                        && content(.toggleFullScreen) == .light(.fullScreen)
                        && content(.quitApp) == .quitApp
                        && content(.quitWindowApp) == .quitApp
                        && Content(.unrecognized) == .unrecognized,
                     "window buttons preview as traffic lights, quitting as the red light with the app")
        suite.expect(content(.close).isAtPointer && content(.quitApp).isAtPointer
                        && !content(.leftHalf).isAtPointer && !Content(.unrecognized).isAtPointer,
                     "lights sit on the pointer, zones and the question mark on the screen")
        suite.expect(Action.allCases.allSatisfy { content($0) != .unrecognized },
                     "every action has a preview")

        let side = 1000.0
        let reference = CGRect(x: 0, y: 0, width: side, height: side)
        func zone(_ layoutAction: WindowLayoutAction) -> Content {
            let rect = WindowLayoutGeometry.rect(for: layoutAction, current: reference, visibleFrame: reference)
            return .zone(CGRect(x: rect.minX / side, y: (side - rect.maxY) / side,
                                width: rect.width / side, height: rect.height / side))
        }
        suite.expect(content(.minimizeAllWindows) == .light(.minimize)
                        && content(.restorePlacement) == .symbol("arrow.uturn.backward")
                        && !content(.restorePlacement).isAtPointer,
                     "a held modifier's minimize-all previews like minimize, undoing previews as its own symbol")
        suite.expect(content(.marginMaximize) == zone(.marginMaximize),
                     "margin maximize previews the same zone the placement itself computes")
        suite.expect(content(.moveToPreviousDisplay) == .zone(CGRect(x: 0, y: 0, width: 0.08, height: 1))
                        && content(.moveToNextDisplay) == .zone(CGRect(x: 0.92, y: 0, width: 0.08, height: 1)),
                     "moving to another display previews a sliver at the edge the window leaves through")
    }

    private static func previewPlacement(_ suite: TestSuite) {
        typealias Placement = ForkTrackpadPreviewPlacement
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        suite.expect(Placement.frame(size: CGSize(width: 54, height: 54), centeredOn: CGPoint(x: 700, y: 400),
                                     within: screen) == CGRect(x: 673, y: 373, width: 54, height: 54)
                        && Placement.frame(size: CGSize(width: 54, height: 54), centeredOn: CGPoint(x: 10, y: 5),
                                           within: screen) == CGRect(x: 0, y: 0, width: 54, height: 54)
                        && Placement.frame(size: CGSize(width: 54, height: 54), centeredOn: CGPoint(x: 1435, y: 898),
                                           within: screen) == CGRect(x: 1386, y: 846, width: 54, height: 54),
                     "the badge sits on the pointer and moves in just enough to stay on its screen")
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let screens = [left, right]
        suite.expect(Placement.screenIndex(targetFrame: CGRect(x: 1300, y: 100, width: 400, height: 300),
                                           pointer: CGPoint(x: 1350, y: 110), screens: screens) == 1,
                     "the HUD goes on the screen holding most of the window, not the pointer's")
        suite.expect(Placement.screenIndex(targetFrame: nil, pointer: CGPoint(x: 2000, y: 1070),
                                           screens: screens) == 1
                        && Placement.screenIndex(targetFrame: CGRect(x: 5000, y: 0, width: 10, height: 10),
                                                 pointer: CGPoint(x: 10, y: 10), screens: screens) == 0,
                     "without a window on screen, the HUD follows the pointer")
        suite.expect(Placement.frame(size: CGSize(width: 160, height: 160),
                                     centeredIn: CGRect(x: 0, y: 25, width: 1440, height: 800))
                        == CGRect(x: 640, y: 345, width: 160, height: 160)
                        && Placement.frame(size: CGSize(width: 44, height: 44), centeredOn: CGPoint(x: 100, y: 50))
                        == CGRect(x: 78, y: 28, width: 44, height: 44),
                     "the HUD is centered on the usable area and the light on the pointer")
    }

    // MARK: - Gestures switched off one by one

    private static func disabledGestures(_ suite: TestSuite) {
        var minimizeOff = Driver(suite) { $0.disabledActions = [.minimize] }
        minimizeOff.scroll(.began)
        minimizeOff.move(dy: 40)
        let silent = minimizeOff.lastPreview == .some(.unrecognized)
        minimizeOff.scroll(.ended)
        suite.expect(silent && minimizeOff.commits.isEmpty, "a disabled gesture neither previews nor acts")

        var quarter = Driver(suite) { $0.disabledActions = [.minimize] }
        quarter.scroll(.began)
        quarter.move(dy: 40)
        quarter.wait(0.35)
        quarter.move(dx: 40)
        quarter.scroll(.ended)
        var half = Driver(suite) { $0.disabledActions = [.minimize] }
        half.scroll(.began)
        half.move(dy: 40)
        half.wait(0.35)
        half.move(dy: 40)
        half.scroll(.ended)
        suite.expect(quarter.commits == [.bottomRightQuarter] && half.commits == [.bottomHalf],
                     "the other gestures of a family still work")

        var closeOff = Driver(suite) { $0.disabledActions = [.close] }
        closeOff.pinch(to: [-0.05, -0.14])
        closeOff.wait(0.2)
        let nothing = closeOff.commits.isEmpty
        closeOff.wait(0.5)
        closeOff.pinch(to: [0.05, 0.15])
        closeOff.wait(0.2)
        suite.expect(nothing && closeOff.commits == [.toggleFullScreen], "closing off leaves full screen working")

        var quitOff = Driver(suite, blocks: true) { $0.disabledActions = [.quitApp] }
        quitOff.onTarget = .dockApp
        quitOff.pinch(to: [-0.03, -0.08, -0.14])
        quitOff.wait(0.2)
        suite.expect(quitOff.commits.isEmpty && quitOff.effects.isEmpty && Set(quitOff.dispositions) == [.pass],
                     "quitting off leaves the Dock its pinch")

        let swipeActions = Set(ForkTrackpadGestureCatalog.entries.filter { $0.family == .swipe }.map(\.action))
        var allOff = Driver(suite) { $0.disabledActions = swipeActions }
        allOff.swipe(dx: 40)
        suite.expect(allOff.commits.isEmpty && allOff.hitTests == 0 && Set(allOff.dispositions) == [.pass],
                     "with every swipe off, not even a hit test")
    }

    // MARK: - Deadlines

    private static func deadlines(_ suite: TestSuite) {
        var reset = Driver(suite)
        reset.scroll(.began)
        reset.move(dx: 40)
        let effects = reset.machine.reset()
        suite.expect(effects == [.hidePreview] && !reset.machine.isTracking && reset.machine.nextDeadline == nil,
                     "reset drops the gesture and hides the preview")
        reset.scroll(.ended)
        suite.expect(reset.commits.isEmpty, "the end of a dropped gesture fires nothing")

        suite.expect(Machine().nextDeadline == nil, "no deadline while idle")

        var step = Driver(suite)
        step.scroll(.began)
        let cancelDeadline = step.machine.nextDeadline.map { abs($0 - (step.now + 0.8)) < 1e-9 } ?? false
        step.move(dx: 40)
        let stepDeadline = step.machine.nextDeadline.map { abs($0 - (step.now + 0.15)) < 1e-9 } ?? false
        suite.expect(cancelDeadline && stepDeadline,
                     "the deadline is the cancel timeout, then the step pause once a direction is candidate")

        // A host woken right at the deadline, with a clock far from zero like
        // `systemUptime`: rounding must not miss it. Several magnitudes,
        // because the rounding depends on them.
        let starts = [1_000.0, 10_000.0, 100_000.0, 1_000_000.0].flatMap { base in
            (0..<20).map { base + Double($0) * 0.37 }
        }
        var missed: [Double] = []
        for start in starts {
            var pause = Driver(suite)
            pause.now = start
            pause.scroll(.began)
            pause.move(dy: -40)
            pause.now = pause.machine.nextDeadline ?? pause.now
            pause.send(.tick, after: 0)

            var cancel = Driver(suite)
            cancel.now = start
            cancel.scroll(.began)
            cancel.move(dy: -40)
            cancel.wait(0.2)
            cancel.now = cancel.machine.nextDeadline ?? cancel.now
            cancel.send(.tick, after: 0)

            var pinch = Driver(suite)
            pinch.now = start
            pinch.pinch(to: [0.05, 0.2])
            pinch.now = pinch.machine.nextDeadline ?? pinch.now
            pinch.send(.tick, after: 0)

            if pause.haptics != [.step] || cancel.haptics != [.step, .cancel]
                || pinch.commits != [.toggleFullScreen] {
                missed.append(start)
            }
        }
        suite.expect(missed.isEmpty, "a tick exactly at the deadline is enough far from zero (missed at \(missed))")

        var fifteen = Driver(suite)
        fifteen.scroll(.began)
        fifteen.move(dy: -40)
        fifteen.wait(0.14)
        let early = fifteen.haptics.isEmpty
        fifteen.wait(0.02)
        let validated = fifteen.haptics == [.step]
        fifteen.move(dy: -40)
        fifteen.scroll(.ended)
        suite.expect(early && validated && fifteen.commits == [.topHalf],
                     "0.15 s of stillness validate a step")
    }

    // MARK: - Unlimited chains, fingers down

    private static func chains(_ suite: TestSuite) {
        var three = Driver(suite)
        three.scroll(.began)
        three.move(dy: -40)
        three.wait(0.35)
        three.move(dx: 40)
        three.wait(0.35)
        let topRight = three.lastPreview == .some(.action(.topRightQuarter))
        three.move(dy: 40)
        let bottomRight = three.lastPreview == .some(.action(.bottomRightQuarter))
        three.scroll(.ended)
        suite.expect(topRight && bottomRight && three.commits == [.bottomRightQuarter]
                        && three.haptics == [.step, .step, .step],
                     "changing one's mind across three steps lands on the latest quarter, "
                        + "the third ticking at once since the quarter already stood")

        var four = Driver(suite)
        four.scroll(.began)
        for (dx, dy) in [(-40.0, 0.0), (0, 40), (40, 0)] {
            four.move(dx: dx, dy: dy)
            four.wait(0.35)
        }
        four.move(dy: -40)
        four.scroll(.ended)
        suite.expect(four.commits == [.topRightQuarter]
                        && four.haptics == Array(repeating: .step, count: 4),
                     "four steps keep following the latest of each axis, the last two live once "
                        + "a quarter already stood, each still ticking on its own")

        // The full shape of a reversal once a quarter stands: a push past the
        // threshold the other way flips that axis straight across, never
        // through a half in between; easing back toward the middle lets that
        // axis go, landing on the half the other axis still holds.
        var reverse = Driver(suite)
        reverse.scroll(.began)
        reverse.move(dy: -40)
        reverse.wait(0.35)
        reverse.move(dx: 40)
        reverse.wait(0.35)
        let topRightFirst = reverse.lastPreview == .some(.action(.topRightQuarter))
        reverse.move(dx: -40)
        let flippedLeft = reverse.lastPreview == .some(.action(.topLeftQuarter))
        reverse.move(dy: 40)
        let flippedDown = reverse.lastPreview == .some(.action(.bottomLeftQuarter))
        reverse.move(dx: 33)
        let easedToHalf = reverse.lastPreview == .some(.action(.bottomHalf))
        reverse.scroll(.ended)
        suite.expect(topRightFirst && flippedLeft && flippedDown && easedToHalf
                        && reverse.commits == [.bottomHalf]
                        && reverse.haptics == Array(repeating: .step, count: 5),
                     "once a quarter stands, a reversal flips straight to the other quarter and "
                        + "easing back to the middle lets go to the half, all without a pause")

        var downTwice = Driver(suite)
        downTwice.scroll(.began)
        for (dx, dy) in [(-40.0, 0.0), (0, -40), (0, 40)] {
            downTwice.move(dx: dx, dy: dy)
            downTwice.wait(0.35)
        }
        let bottomLeft = downTwice.lastPreview == .some(.action(.bottomLeftQuarter))
        downTwice.move(dx: 3)
        let bottomHalf = downTwice.lastPreview == .some(.action(.bottomHalf))
        downTwice.scroll(.ended)
        suite.expect(bottomLeft && bottomHalf && downTwice.commits == [.bottomHalf]
                        && downTwice.haptics == Array(repeating: .step, count: 4),
                     "easing the horizontal back to the middle lets go to the half, now that "
                        + "pushing the vertical further no longer forces it on its own")

        // The hysteresis band's exact edges: short of the release threshold
        // an axis holds, short of the full threshold a fresh axis never
        // enters, and a diagonal's own corner seeds its two axes the same
        // way a two-step quarter does.
        var edges = Driver(suite)
        edges.scroll(.began)
        edges.move(dx: 40, dy: -40)
        edges.wait(0.35)
        // Seeded at accX=+5 (the default swipeThreshold); release sits at 2.5.
        edges.move(dx: -2)
        let stillRight = edges.lastPreview == .some(.action(.topRightQuarter))
        edges.move(dx: -1)
        let releasedHorizontal = edges.lastPreview == .some(.action(.topHalf))
        edges.move(dx: -2)
        let notYetFlipped = edges.lastPreview == .some(.action(.topHalf))
        edges.move(dx: -5)
        let edgeFlippedLeft = edges.lastPreview == .some(.action(.topLeftQuarter))
        edges.scroll(.ended)
        suite.expect(stillRight && releasedHorizontal && notYetFlipped && edgeFlippedLeft,
                     "a quarter's own diagonal seeds its axes at the threshold too: holds past the "
                        + "release band (accX=3), lets go right at it (accX=2≤2.5), stays let go well "
                        + "short of the far threshold (accX=0), then only flips once fully crossed (accX=-5)")

        var oneAxis = Driver(suite)
        oneAxis.scroll(.began)
        oneAxis.move(dy: -40)
        oneAxis.wait(0.35)
        oneAxis.move(dy: 40)
        let minimizes = oneAxis.lastPreview == .some(.action(.minimize))
        oneAxis.scroll(.ended)
        suite.expect(minimizes && oneAxis.commits == [.minimize],
                     "changing one's mind on one axis before a quarter ever exists simply lands on "
                        + "that axis's own latest meaning")
    }

    // MARK: - Host

    private static func decoding(_ suite: TestSuite) {
        typealias Decoding = ForkTrackpadEventDecoding
        suite.expect(Decoding.gestureKind(subtype: 8) == .magnify
                        && Decoding.gestureKind(subtype: 22) == .smartMagnify
                        && Decoding.gestureKind(subtype: 6) == nil
                        && Decoding.gestureKind(subtype: 0) == nil,
                     "gesture subtypes: 8 is a pinch, 22 the smart zoom double tap, others are ignored")

        let phases: [(UInt, Machine.Phase?)] = [
            (0x20, .mayBegin), (0x1, .began), (0x4, .changed), (0x2, .changed),
            (0x8, .ended), (0x10, .cancelled), (0, nil),
        ]
        suite.expect(phases.allSatisfy { Decoding.phase(appKitRawValue: $0.0) == $0.1 },
                     "AppKit phases map one to one, stationary reads as changed, none as nil")
        suite.expect(Decoding.phase(appKitRawValue: 0x20 | 0x1) == .mayBegin
                        && Decoding.phase(appKitRawValue: 0x1 | 0x8) == .began
                        && Decoding.phase(appKitRawValue: 0x4 | 0x8) == .changed
                        && Decoding.phase(appKitRawValue: 0x8 | 0x10) == .ended,
                     "a combined phase reads as the earliest stage it carries")

        let natural = Decoding.scrollDelta(dx: -3, dy: 7, directionInvertedFromDevice: true)
        let classic = Decoding.scrollDelta(dx: -3, dy: 7, directionInvertedFromDevice: false)
        suite.expect(natural.dx == -3 && natural.dy == 7 && classic.dx == 3 && classic.dy == -7,
                     "deltas keep their sign with Natural scrolling on and flip with it off")
    }

    private static func clock(_ suite: TestSuite) {
        var clock = ForkTrackpadGestureClock()
        let first = clock.time(for: 10)
        let later = clock.time(for: 10.5)
        let stale = clock.time(for: 10.2)
        let next = clock.time(for: 11)
        suite.expect(first == 10 && later == 10.5 && stale == 10.5 && next == 11,
                     "gesture time follows event timestamps and never goes back")
    }

    private static func center(_ suite: TestSuite) {
        let visible = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let rect = ForkTrackpadCenter.rect(in: visible)
        suite.expect(rect == CGRect(x: 300, y: 210, width: 600, height: 480),
                     "a double tap centers the window at 60 % of the usable area")
        suite.expect(ForkTrackpadCenter.rect(in: visible, scale: 1) == visible
                        && ForkTrackpadCenter.rect(in: visible, scale: 3) == visible,
                     "the center scale stops at the whole usable area")
        suite.expect(ForkTrackpadCenter.rect(in: visible, scale: 0)
                        == CGRect(x: 550, y: 410, width: 100, height: 80),
                     "the center scale never goes under 10 %")
    }

    private static func halves(_ suite: TestSuite) {
        typealias Half = ForkLayoutHalf
        suite.expect(Half.allCases.allSatisfy { Half($0.action) == $0 && $0.complement.complement == $0 }
                        && Half.left.complement == .right && Half.top.complement == .bottom,
                     "each half names its layout action and faces the opposite half")
        suite.expect(Half(.topLeft) == nil && Half(.maximize) == nil && Half(.leftThird) == nil,
                     "only the four halves have a facing half")
    }

    private static func complementaryHalves(_ suite: TestSuite) {
        typealias Complement = ForkLayoutComplement
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: 0, y: 0, width: 720, height: 900)
        let right = CGRect(x: 720, y: 0, width: 720, height: 900)
        func fit(_ half: ForkLayoutHalf, _ theoretical: CGRect, gap: CGFloat = 0,
                 _ neighbour: CGRect?) -> CGRect {
            Complement.rect(for: half, theoretical: theoretical, layoutFrame: frame,
                            windowGap: gap, neighbour: neighbour)
        }

        suite.expect(fit(.left, left, nil) == left,
                     "without a window in the facing half, the half is the theoretical one")
        suite.expect(fit(.left, left, CGRect(x: 620, y: 0, width: 820, height: 900))
                        == CGRect(x: 0, y: 0, width: 620, height: 900),
                     "a left half narrows to meet a right window wider than its half")
        suite.expect(fit(.left, left, CGRect(x: 800, y: 0, width: 640, height: 900))
                        == CGRect(x: 0, y: 0, width: 800, height: 900)
                        && fit(.right, right, CGRect(x: 0, y: 0, width: 600, height: 900))
                        == CGRect(x: 600, y: 0, width: 840, height: 900),
                     "a half widens to meet a neighbour narrower than its half, both ways")
        suite.expect(fit(.left, left, CGRect(x: 600, y: 0, width: 700, height: 900)) == left
                        && fit(.left, left, CGRect(x: 600, y: 0, width: 838, height: 900))
                        == CGRect(x: 0, y: 0, width: 600, height: 900)
                        && fit(.left, left, CGRect(x: 600, y: 0, width: 837, height: 900)) == left,
                     "a neighbour off its outer edge no longer holds its half, 2 pt of rounding aside")
        suite.expect(fit(.left, left, CGRect(x: 359, y: 0, width: 1081, height: 900)) == left
                        && fit(.left, left, CGRect(x: 360, y: 0, width: 1080, height: 900))
                        == CGRect(x: 0, y: 0, width: 360, height: 900),
                     "under a quarter of the screen the half falls back to the theoretical one")

        let gappedLeft = CGRect(x: 0, y: 0, width: 712, height: 900)
        let gappedRight = CGRect(x: 728, y: 0, width: 712, height: 900)
        suite.expect(fit(.left, gappedLeft, gap: 16, gappedRight) == gappedLeft
                        && fit(.left, gappedLeft, gap: 16, CGRect(x: 600, y: 0, width: 840, height: 900))
                        == CGRect(x: 0, y: 0, width: 584, height: 900)
                        && fit(.right, gappedRight, gap: 16, CGRect(x: 0, y: 0, width: 700, height: 900))
                        == CGRect(x: 716, y: 0, width: 724, height: 900),
                     "the window gap stays between the two halves")

        let top = CGRect(x: 0, y: 450, width: 1440, height: 450)
        let bottom = CGRect(x: 0, y: 0, width: 1440, height: 450)
        suite.expect(fit(.top, top, CGRect(x: 0, y: 0, width: 1440, height: 500))
                        == CGRect(x: 0, y: 500, width: 1440, height: 400)
                        && fit(.bottom, bottom, CGRect(x: 0, y: 380, width: 1440, height: 520))
                        == CGRect(x: 0, y: 0, width: 1440, height: 380),
                     "top and bottom halves meet the same way, top at the high y")
        suite.expect(fit(.top, top, CGRect(x: 0, y: 0, width: 1440, height: 500).offsetBy(dx: 0, dy: 10)) == top,
                     "a bottom window lifted off the bottom edge no longer holds its half")
        let inset = CGRect(x: 20, y: 450, width: 1400, height: 430)
        suite.expect(fit(.top, inset, CGRect(x: 0, y: 0, width: 1440, height: 500))
                        == CGRect(x: 20, y: 500, width: 1400, height: 400),
                     "fitting only moves the shared edge; the other axis keeps the half's own")
    }

    private static func complementRefit(_ suite: TestSuite) {
        typealias Complement = ForkLayoutComplement
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: 0, y: 0, width: 720, height: 900)
        func refit(_ current: CGRect, gap: CGFloat = 0, to neighbour: CGRect) -> CGRect? {
            Complement.refitRect(for: .left, current: current, theoretical: left, layoutFrame: frame,
                                 windowGap: gap, neighbour: neighbour)
        }

        suite.expect(refit(left, to: CGRect(x: 620, y: 0, width: 820, height: 900))
                        == CGRect(x: 0, y: 0, width: 620, height: 900),
                     "the left window moves back to meet a right window that settled wider")
        suite.expect(refit(left, to: CGRect(x: 720, y: 0, width: 720, height: 900)) == nil
                        && refit(left, to: CGRect(x: 721, y: 0, width: 719, height: 900)) == nil
                        && refit(left, to: CGRect(x: 722, y: 0, width: 718, height: 900))
                        == CGRect(x: 0, y: 0, width: 722, height: 900),
                     "windows that already meet stay put, within a point")
        suite.expect(refit(left, to: CGRect(x: 600, y: 0, width: 700, height: 900)) == nil
                        && refit(left, to: CGRect(x: 200, y: 0, width: 1240, height: 900)) == nil,
                     "no refit toward a neighbour off its edge or under the minimum share")
        suite.expect(refit(CGRect(x: 0, y: 0, width: 712, height: 900), gap: 16,
                           to: CGRect(x: 728, y: 0, width: 712, height: 900)) == nil
                        && refit(CGRect(x: 0, y: 0, width: 712, height: 900), gap: 16,
                                 to: CGRect(x: 700, y: 0, width: 740, height: 900))
                        == CGRect(x: 0, y: 0, width: 684, height: 900),
                     "meeting means one window gap apart")
        suite.expect(Complement.meets(CGRect(x: 0, y: 450, width: 1440, height: 450), in: .top,
                                      neighbour: CGRect(x: 0, y: 0, width: 1440, height: 450), windowGap: 0)
                        && !Complement.meets(CGRect(x: 0, y: 460, width: 1440, height: 440), in: .top,
                                             neighbour: CGRect(x: 0, y: 0, width: 1440, height: 450),
                                             windowGap: 0)
                        && Complement.meets(CGRect(x: 0, y: 0, width: 1440, height: 442), in: .bottom,
                                            neighbour: CGRect(x: 0, y: 458, width: 1440, height: 442),
                                            windowGap: 16),
                     "top and bottom meet across the horizontal edge")
    }

    private static func halfMemory(_ suite: TestSuite) {
        typealias Memory = ForkLayoutHalfMemory<Int>
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let other = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let rect = CGRect(x: 0, y: 0, width: 720, height: 900)
        var memory = Memory()
        memory.record(1, in: .left, layoutFrame: screen, frame: rect)
        suite.expect(memory.occupant(of: .left, layoutFrame: screen)?.window == 1
                        && memory.occupant(of: .right, layoutFrame: screen) == nil
                        && memory.occupant(of: .left, layoutFrame: other) == nil,
                     "a half is remembered for one layout frame only")
        memory.record(1, in: .right, layoutFrame: screen, frame: rect)
        suite.expect(memory.occupant(of: .left, layoutFrame: screen) == nil
                        && memory.occupant(of: .right, layoutFrame: screen)?.window == 1,
                     "a window holds one half at a time")
        memory.record(2, in: .right, layoutFrame: screen, frame: rect)
        suite.expect(memory.occupant(of: .right, layoutFrame: screen)?.window == 2
                        && memory.entry(for: 1) == nil && memory.entries.count == 1,
                     "a window sent to a held half takes it over")
        let moved = CGRect(x: 700, y: 0, width: 740, height: 900)
        memory.update(2, frame: moved)
        memory.update(3, frame: rect)
        suite.expect(memory.entry(for: 2)?.frame == moved && memory.entry(for: 3) == nil,
                     "a read-back updates a remembered window and nothing else")
        memory.forget(2)
        suite.expect(memory.entries.isEmpty, "a forgotten window leaves its half")

        for index in 0...Memory.limit {
            memory.record(index, in: .left,
                          layoutFrame: screen.offsetBy(dx: CGFloat(index) * 2000, dy: 0), frame: rect)
        }
        suite.expect(memory.entries.count == Memory.limit && memory.entry(for: 0) == nil
                        && memory.entry(for: Memory.limit) != nil,
                     "the memory stays bounded, the oldest half going first")

        suite.expect(Memory.isStillPlaced(recorded: rect, actual: rect.insetBy(dx: 1, dy: 1))
                        && !Memory.isStillPlaced(recorded: rect, actual: rect.offsetBy(dx: 3, dy: 0))
                        && !Memory.isStillPlaced(recorded: rect, actual: rect.offsetBy(dx: 0, dy: -3))
                        && !Memory.isStillPlaced(recorded: rect,
                                                 actual: CGRect(x: 0, y: 0, width: 723, height: 900))
                        && !Memory.isStillPlaced(recorded: rect,
                                                 actual: CGRect(x: 0, y: 0, width: 720, height: 897))
                        && !Memory.isStillPlaced(recorded: rect, actual: nil),
                     "a window moved, resized or closed no longer holds its half")
    }

    private static func modifierRemap(_ suite: TestSuite) {
        typealias Remap = ForkTrackpadModifierRemap
        suite.expect(Remap.action(for: .minimize, modifierHeld: false) == .minimize
                        && Remap.action(for: .maximize, modifierHeld: false) == .maximize,
                     "without the modifier, a gesture keeps its plain action")
        suite.expect(Remap.action(for: .minimize, modifierHeld: true) == .minimizeAllWindows
                        && Remap.action(for: .maximize, modifierHeld: true) == .marginMaximize
                        && Remap.action(for: .close, modifierHeld: true) == .quitWindowApp
                        && Remap.action(for: .leftHalf, modifierHeld: true) == .moveToPreviousDisplay
                        && Remap.action(for: .rightHalf, modifierHeld: true) == .moveToNextDisplay
                        && Remap.action(for: .centerReduced, modifierHeld: true) == .restorePlacement,
                     "held, the modifier reaches minimize-all, margin maximize, quitting the app, "
                        + "the next or previous display, and undoing the last placement")
        suite.expect(Remap.action(for: .topHalf, modifierHeld: true) == .topHalf
                        && Remap.action(for: .quitApp, modifierHeld: true) == .quitApp
                        && Remap.action(for: .minimizeAllWindows, modifierHeld: true) == .minimizeAllWindows,
                     "an action the modifier has nothing further to say about stays exactly what it was")
        suite.expect(Remap.action(for: .close, modifierHeld: true, disabled: [.quitWindowApp]) == .close
                        && Remap.action(for: .minimize, modifierHeld: true, disabled: [.quitWindowApp])
                        == .minimizeAllWindows,
                     "quitting the app keeps its own switch even reached through a held modifier")

        typealias Action = ForkTrackpadGestureAction
        suite.expect(!Action.quitApp.isWindowAction && !Action.emptyTrash.isWindowAction
                        && !Action.showAppWindows.isWindowAction && !Action.restoreMinimizedWindow.isWindowAction
                        && !Action.closeMinimizedWindow.isWindowAction,
                     "the Dock's own gestures never reach a window")
        suite.expect(Action.allCases.filter { !$0.isWindowAction }.count == 7
                        && [Action.leftHalf, .minimize, .centerReduced, .minimizeAllWindows, .marginMaximize,
                            .moveToPreviousDisplay, .moveToNextDisplay, .restorePlacement]
                            .allSatisfy(\.isWindowAction),
                     "every other action, the held modifier's own included, can reach a window")
    }

    private static func gridResolve(_ suite: TestSuite) {
        typealias Sequence = ForkTrackpadGestureSequence
        func column(_ index: Int, _ span: Int) -> (column: Int, span: Int) { (column: index, span: span) }
        func edge(_ direction: Swipe, _ span: Int) -> (edge: Swipe, span: Int) { (edge: direction, span: span) }

        suite.expect(Sequence.resolveGrid(horizontal: nil, vertical: nil) == nil,
                     "nothing held on either axis names nothing")
        suite.expect(Sequence.resolveGrid(horizontal: column(0, 1), vertical: nil) == .leftThird
                        && Sequence.resolveGrid(horizontal: column(2, 1), vertical: nil) == .rightThird
                        && Sequence.resolveGrid(horizontal: column(0, 2), vertical: nil) == .leftTwoThirds
                        && Sequence.resolveGrid(horizontal: column(1, 2), vertical: nil) == .rightTwoThirds,
                     "a third or two thirds alone, from its own edge, with no vertical held")
        suite.expect(Sequence.resolveGrid(horizontal: column(1, 1), vertical: nil) == .centerThird,
                     "sliding on past two thirds, with no vertical held, reaches the centre "
                        + "third itself, on the way to the far edge's own third")
        suite.expect(Sequence.resolveGrid(horizontal: nil, vertical: edge(.up, 1)) == .topHalf
                        && Sequence.resolveGrid(horizontal: nil, vertical: edge(.down, 1)) == .bottomHalf,
                     "a vertical half alone, with no horizontal held")
        suite.expect(Sequence.resolveGrid(horizontal: nil, vertical: edge(.up, 2)) == .topCenterSixth
                        && Sequence.resolveGrid(horizontal: nil, vertical: edge(.down, 2)) == .bottomCenterSixth,
                     "a vertical half pushed a second stop further, with no horizontal ever "
                        + "joining it, names the sixth down its own centre column")
        suite.expect(Sequence.resolveGrid(horizontal: column(0, 1), vertical: edge(.up, 1)) == .topLeftSixth
                        && Sequence.resolveGrid(horizontal: column(2, 1), vertical: edge(.up, 1)) == .topRightSixth
                        && Sequence.resolveGrid(horizontal: column(0, 1), vertical: edge(.down, 1)) == .bottomLeftSixth
                        && Sequence.resolveGrid(horizontal: column(2, 1), vertical: edge(.down, 1)) == .bottomRightSixth,
                     "a third and a vertical half together name their corner sixth")
        suite.expect(Sequence.resolveGrid(horizontal: column(0, 2), vertical: edge(.up, 1)) == .topLeftTwoSixths
                        && Sequence.resolveGrid(horizontal: column(1, 2), vertical: edge(.up, 1)) == .topRightTwoSixths
                        && Sequence.resolveGrid(horizontal: column(0, 2), vertical: edge(.down, 1)) == .bottomLeftTwoSixths
                        && Sequence.resolveGrid(horizontal: column(1, 2), vertical: edge(.down, 1)) == .bottomRightTwoSixths,
                     "two of a row's three sixths together, confined to it by the vertical "
                        + "half, name their own shape — the one no plain third ever reaches")
        suite.expect(Sequence.resolveGrid(horizontal: column(1, 1), vertical: edge(.up, 1)) == .topCenterSixth
                        && Sequence.resolveGrid(horizontal: column(1, 1), vertical: edge(.down, 1)) == .bottomCenterSixth,
                     "the row's own centre sixth, reached by sliding across it, names the "
                        + "same action as reaching it by pushing the vertical further alone")
        suite.expect(Sequence.resolveGrid(horizontal: column(0, 1), vertical: edge(.up, 2)) == .topLeftSixth,
                     "once a horizontal column is set, how far out the vertical push went no "
                        + "longer matters: the corner sixth is already fully named")
    }

    private static func grid(_ suite: TestSuite) {
        // A third, with no vertical ever touched: the grid modifier reaches
        // it from a single axis alone, unlike a plain quarter. Pushing
        // further the same way does nothing more — that edge is already
        // pinned to the screen's own edge — but swiping back the other way
        // slides on across the same ladder a row's own sixths use: two
        // thirds, the centre third itself, the far edge's own two thirds,
        // then its third — one stop at a time, never skipping past the
        // centre — and reversing all the way retraces every stop back.
        var third = Driver(suite)
        third.gridModifierHeld = true
        third.scroll(.began)
        third.move(dx: -40)
        third.wait(0.35)
        let isThird = third.lastPreview == .some(.action(.leftThird))
        third.move(dx: 13)
        let passedTwoThirds = third.previews.contains(.some(.action(.leftTwoThirds)))
        let isCenterThird = third.lastPreview == .some(.action(.centerThird))
        third.move(dx: 13)
        let passedRightTwoThirds = third.previews.contains(.some(.action(.rightTwoThirds)))
        let isRightThird = third.lastPreview == .some(.action(.rightThird))
        third.move(dx: -33)
        let backToLeftThird = third.lastPreview == .some(.action(.leftThird))
        third.scroll(.ended)
        suite.expect(isThird && passedTwoThirds && isCenterThird && passedRightTwoThirds
                        && isRightThird && backToLeftThird && third.commits == [.leftThird],
                     "a third slides through two thirds, the centre third itself, the far "
                        + "edge's own two thirds and its third, one stop at a time, and "
                        + "reversing all the way retraces every stop back")

        // Pushing hard back toward the original edge, from two thirds,
        // shrinks straight back to the plain third rather than lingering
        // in between.
        var shrink = Driver(suite)
        shrink.gridModifierHeld = true
        shrink.scroll(.began)
        shrink.move(dx: -40)
        shrink.wait(0.35)
        shrink.move(dx: 8)
        let shrinkIsTwoThirds = shrink.lastPreview == .some(.action(.leftTwoThirds))
        shrink.move(dx: -20)
        let backToThird = shrink.lastPreview == .some(.action(.leftThird))
        shrink.scroll(.ended)
        suite.expect(shrinkIsTwoThirds && backToThird && shrink.commits == [.leftThird]
                        && shrink.haptics == Array(repeating: .step, count: 3),
                     "pushing hard back toward the original edge, even from two thirds, "
                        + "shrinks straight back to the plain third rather than growing further")

        // A vertical half, with no horizontal ever joining it, pushed a
        // second stop further: the sixth down its own centre column,
        // reached the way Swish's own help text describes it (swiping up
        // twice) — the only way to name it, since no key points straight at
        // the centre.
        var center = Driver(suite)
        center.gridModifierHeld = true
        center.scroll(.began)
        center.move(dy: -40)
        center.wait(0.35)
        let centerIsTopHalf = center.lastPreview == .some(.action(.topHalf))
        center.move(dy: -10)
        let isTopCenterSixth = center.lastPreview == .some(.action(.topCenterSixth))
        center.scroll(.ended)
        suite.expect(centerIsTopHalf && isTopCenterSixth && center.commits == [.topCenterSixth]
                        && center.haptics == Array(repeating: .step, count: 2),
                     "a vertical half pushed further still, with no horizontal ever joining "
                        + "it, reaches the sixth down its own centre column")

        // A sixth: the vertical joins afterwards, live, with no pause of its
        // own needed either, since the grid already took over after the
        // first step.
        var sixth = Driver(suite)
        sixth.gridModifierHeld = true
        sixth.scroll(.began)
        sixth.move(dx: -40)
        sixth.wait(0.35)
        sixth.move(dy: -40)
        let isSixth = sixth.lastPreview == .some(.action(.topLeftSixth))
        sixth.scroll(.ended)
        suite.expect(isSixth && sixth.commits == [.topLeftSixth]
                        && sixth.haptics == [.step, .step],
                     "a vertical half joins a third live to name their corner sixth")

        // A vertical half alone, with the grid modifier held: straight to
        // the half, no doubled step needed the way a plain maximize would.
        var half = Driver(suite)
        half.gridModifierHeld = true
        half.scroll(.began)
        half.move(dy: -40)
        half.wait(0.35)
        let isTopHalf = half.lastPreview == .some(.action(.topHalf))
        half.scroll(.ended)
        suite.expect(isTopHalf && half.commits == [.topHalf],
                     "the grid modifier reaches a vertical half from a single step, not maximize, "
                        + "and not a doubled step either")

        // Whichever tracking a gesture settles into — plain or grid — is
        // decided once, by the modifier's state right when it settles, and
        // does not switch again from a later change of mind about the key.
        var locked = Driver(suite)
        locked.scroll(.began)
        locked.move(dx: -40)
        locked.wait(0.35)
        locked.move(dy: -40)
        locked.wait(0.35)
        locked.gridModifierHeld = true
        locked.move(dx: 40)
        let stillPlainQuarter = locked.lastPreview == .some(.action(.topRightQuarter))
        locked.scroll(.ended)
        suite.expect(stillPlainQuarter && locked.commits == [.topRightQuarter],
                     "a plain quarter already under way keeps its own tracking even once the grid "
                        + "modifier is pressed, and only reverses the side it was asked to")
    }

    private static func gridRow(_ suite: TestSuite) {
        // Once a vertical half confines the window to a row, sliding across
        // it in one direction visits every one of its five stops in order —
        // the near sixth, the two sixths beside it, the centre sixth, the
        // far two sixths, the far sixth — and reversing retraces them back,
        // the same way the plain third's own growth and flip do.
        var row = Driver(suite)
        row.gridModifierHeld = true
        row.scroll(.began)
        row.move(dx: -40)
        row.wait(0.35)
        let isLeftThird = row.lastPreview == .some(.action(.leftThird))
        row.move(dy: -40)
        let isTopLeftSixth = row.lastPreview == .some(.action(.topLeftSixth))
        row.move(dx: 13)
        let passedTopLeftTwoSixths = row.previews.contains(.some(.action(.topLeftTwoSixths)))
        let isTopCenterSixth = row.lastPreview == .some(.action(.topCenterSixth))
        row.move(dx: 13)
        let passedTopRightTwoSixths = row.previews.contains(.some(.action(.topRightTwoSixths)))
        let isTopRightSixth = row.lastPreview == .some(.action(.topRightSixth))
        row.move(dx: -33)
        let backToTopLeftSixth = row.lastPreview == .some(.action(.topLeftSixth))
        row.scroll(.ended)
        suite.expect(isLeftThird && isTopLeftSixth && passedTopLeftTwoSixths && isTopCenterSixth
                        && passedTopRightTwoSixths && isTopRightSixth && backToTopLeftSixth
                        && row.commits == [.topLeftSixth],
                     "sliding across a row in one direction visits every stop in order — the "
                        + "near sixth, the two sixths beside it, the centre sixth, the far two "
                        + "sixths, the far sixth — and reversing retraces them back")

        // A hand wobbling the vertical while sliding — easing it off past
        // its own release band, then pushing it back past the threshold —
        // must never throw the ladder back to wherever `accX` happens to
        // sit: it stays exactly where the slide last left it, read-only
        // while the vertical is let go, and resumes naming its row once
        // the vertical recommits.
        var wobble = Driver(suite)
        wobble.gridModifierHeld = true
        wobble.scroll(.began)
        wobble.move(dx: -40)
        wobble.wait(0.35)
        wobble.move(dy: -8)
        let wobbleIsTopLeftSixth = wobble.lastPreview == .some(.action(.topLeftSixth))
        wobble.move(dx: 13)
        let wobbleIsTopCenterSixth = wobble.lastPreview == .some(.action(.topCenterSixth))
        wobble.move(dy: 6)
        wobble.move(dx: 13)
        wobble.move(dy: -8.5)
        let backToTopRightSixth = wobble.lastPreview == .some(.action(.topRightSixth))
        wobble.scroll(.ended)
        suite.expect(wobbleIsTopLeftSixth && wobbleIsTopCenterSixth && backToTopRightSixth
                        && wobble.commits == [.topRightSixth],
                     "a vertical wobble mid-slide — easing the row off and recommitting it — "
                        + "never resets where the ladder stood: sliding on and reconfirming the "
                        + "row lands exactly where the ladder already was")
    }

    private static func diagnostics(_ suite: TestSuite) {
        typealias Check = ForkTrackpadDiagnosticCheck
        suite.expect(Check.allCases.count == 3
                        && Check.smartZoom.preferenceKey == "TrackpadTwoFingerDoubleTapGesture"
                        && Check.pinchToZoom.preferenceKey == "TrackpadPinch"
                        && Check.forceClickHaptics.preferenceKey == "ActuateDetents",
                     "each diagnostic reads the preference key System Settings itself writes")
        suite.expect(Check.preferenceDomains == ["com.apple.AppleMultitouchTrackpad",
                                                 "com.apple.driver.AppleBluetoothMultitouch.trackpad"],
                     "the built-in trackpad is read before the Bluetooth one")

        func reading(_ answers: [String: Bool?]) -> (String, String) -> Bool? {
            { key, domain in answers["\(key)|\(domain)"] ?? nil }
        }
        suite.expect(Check.smartZoom.isEnabled(reading: reading([
            "TrackpadTwoFingerDoubleTapGesture|com.apple.AppleMultitouchTrackpad": true,
        ])) == true, "on for the built-in trackpad reads as on")
        suite.expect(Check.smartZoom.isEnabled(reading: reading([
            "TrackpadTwoFingerDoubleTapGesture|com.apple.AppleMultitouchTrackpad": false,
            "TrackpadTwoFingerDoubleTapGesture|com.apple.driver.AppleBluetoothMultitouch.trackpad": true,
        ])) == true, "on for the Bluetooth trackpad alone still reads as on")
        suite.expect(Check.smartZoom.isEnabled(reading: reading([
            "TrackpadTwoFingerDoubleTapGesture|com.apple.AppleMultitouchTrackpad": false,
            "TrackpadTwoFingerDoubleTapGesture|com.apple.driver.AppleBluetoothMultitouch.trackpad": false,
        ])) == false, "off for every trackpad that answered reads as off")
        suite.expect(Check.smartZoom.isEnabled(reading: reading([:])) == nil,
                     "no trackpad known to the system answers nothing, not off")
    }

    private static func windowChain(_ suite: TestSuite) {
        typealias Chain = ForkTrackpadWindowChain
        suite.expect(Chain.nextIndex(current: nil, count: 4, forward: true) == 1
                        && Chain.nextIndex(current: nil, count: 4, forward: false) == 3,
                     "with nothing remembered yet, forward and back both skip the first window")
        suite.expect(Chain.nextIndex(current: 0, count: 4, forward: true) == 1
                        && Chain.nextIndex(current: 1, count: 4, forward: true) == 2
                        && Chain.nextIndex(current: 2, count: 4, forward: true) == 3
                        && Chain.nextIndex(current: 3, count: 4, forward: true) == 0,
                     "forward steps through every window in order, then wraps to the first")
        suite.expect(Chain.nextIndex(current: 0, count: 4, forward: false) == 3
                        && Chain.nextIndex(current: 3, count: 4, forward: false) == 2,
                     "back steps the other way, wrapping past the first to the last")
        suite.expect(Chain.nextIndex(current: 5, count: 4, forward: true) == 2
                        && Chain.nextIndex(current: -1, count: 4, forward: true) == 0,
                     "a remembered position outside today's count still lands inside it")
    }

    private static func sizeCycle(_ suite: TestSuite) {
        typealias Cycle = ForkWindowSizeCycle
        let frame = WindowLayoutFrame(origin: .zero, size: CGSize(width: 720, height: 900))
        let moved = WindowLayoutFrame(origin: CGPoint(x: 40, y: 0), size: frame.size)
        func effective(_ action: WindowLayoutAction, previous: (WindowLayoutAction, WindowLayoutFrame)?,
                      current: WindowLayoutFrame = frame, cyclesThirds: Bool = true) -> WindowLayoutAction {
            Cycle.effectiveAction(for: action, current: current,
                                  previous: previous.map { ($0.0, $0.1) }, tolerance: 8,
                                  cyclesThirds: cyclesThirds)
        }

        suite.expect(effective(.leftHalf, previous: nil) == .leftHalf,
                     "a first half gesture is never advanced")
        suite.expect(effective(.leftHalf, previous: (.leftHalf, frame)) == .leftTwoThirds
                        && effective(.leftHalf, previous: (.leftTwoThirds, frame)) == .leftThird
                        && effective(.leftHalf, previous: (.leftThird, frame)) == .leftHalf,
                     "repeating a left half cycles half, two thirds, third, then back to half")
        suite.expect(effective(.rightHalf, previous: (.rightHalf, frame)) == .rightTwoThirds,
                     "the right half cycles the same way, on its own side")
        suite.expect(effective(.leftHalf, previous: (.leftHalf, frame), cyclesThirds: false) == .leftHalf,
                     "the cycle never advances while the setting that turns it on is off")
        suite.expect(effective(.leftHalf, previous: (.leftHalf, moved)) == .leftHalf,
                     "a window moved away from the remembered frame starts the cycle over")
        suite.expect(effective(.leftHalf, previous: (.rightHalf, frame)) == .leftHalf,
                     "a different previous side never advances this one")
        suite.expect(effective(.topHalf, previous: (.topHalf, frame)) == .maximize
                        && effective(.topHalf, previous: (.topHalf, frame), cyclesThirds: false) == .maximize,
                     "a repeated top half always goes to maximize, whether or not thirds are on")
        suite.expect(effective(.maximize, previous: (.maximize, frame)) == .maximize
                        && effective(.leftThird, previous: (.leftHalf, frame)) == .leftThird,
                     "only a plain left, right or top half is ever advanced")
    }

    private static func complementWiring(_ suite: TestSuite) {
        let service = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadWindowPlacer.swift")
        func body(_ signature: String) -> String {
            let tail = service.components(separatedBy: signature).dropFirst().first ?? ""
            return tail.components(separatedBy: "\n    }\n").first ?? ""
        }
        let gesture = body("func apply(_ action: ForkTrackpadGestureAction, to window: AXUIElement)")
        suite.expect(gesture.contains("if effective == layoutAction, let half = ForkLayoutHalf(effective) {")
                        && gesture.contains("applyHalf(half, to: target, visibleFrame: screen.visibleFrame)"),
                     "trackpad halves go through the complementary placement, unless a repeat advanced the cycle")
        suite.expect(gesture.contains("effectiveAction(for: layoutAction, target: target)")
                        && gesture.components(separatedBy: "recordCycle(effective, target: target)").count - 1 == 2,
                     "every half, quarter or maximize placement records its cycle state")
        suite.expect(gesture.components(separatedBy: "bringForward(target.window, of: app)").count - 1 == 5
                        && body("private func bringForward(").contains("app.activate(options: [])")
                        && body("private func bringForward(").contains("kAXRaiseAction"),
                     "centering and every placement bring the window forward, activating its app")
        let minimize = gesture.components(separatedBy: "case .minimize:").dropFirst().first?
            .components(separatedBy: "case .centerReduced:").first ?? ""
        suite.expect(!minimize.contains("bringForward"),
                     "minimize, close and quit never raise the window first")
        suite.expect(gesture.components(separatedBy: "forgetHalf(target.key)").count - 1 == 6,
                     "centering, full screen and every other placement retire the window's half")
        suite.expect(gesture.contains("case .minimizeAllWindows:")
                        && gesture.contains("case .moveToPreviousDisplay, .moveToNextDisplay:")
                        && gesture.contains("case .restorePlacement:")
                        && gesture.contains("WindowLayoutGeometry.adjacentDisplayIndex(")
                        && gesture.contains("WindowLayoutGeometry.rectForDisplay(")
                        && gesture.contains("beforePlacement[target.key]"),
                     "a held modifier's own actions move every window, the display or undo the last placement")
        let half = body("private func applyHalf(")
        suite.expect(half.contains("neighbour: neighbour?.frame")
                        && half.contains("guard setFrame(axFrame(fromAppKit: rect), targetRect: rect")
                        && half.contains("recordHalf(window, in: half"),
                     "a trackpad half is fitted, applied as fitted, then remembered")
        let refit = body("private func refitHalfNeighbour(")
        suite.expect(refit.contains("ForkLayoutComplement.refitRect(")
                        && refit.contains("forgetHalf(window.key)")
                        && !refit.contains("self?.refitHalfNeighbour(")
                        && !refit.contains("self.refitHalfNeighbour("),
                     "the facing window is refitted once, never refitted back")
        let valid = body("private func validHalfOccupant(")
        suite.expect(valid.contains("kAXMinimizedAttribute") && valid.contains("\"AXFullScreen\"")
                        && valid.contains("onScreenWindowIDs()?.contains(entry.window.key.windowID)")
                        && valid.contains("forgetHalf(entry.window.key)"),
                     "a remembered half no longer counts once minimized, full screen or off screen")
        let gestures = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkGestures.swift")
        let suspend = gestures.components(separatedBy: "static func suspend()").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(body("func reset()").contains("halfMemory.removeAll()")
                        && body("func reset()").contains("cycleMemory.removeAll()")
                        && body("func reset()").contains("timer.invalidate()")
                        && body("func reset()").contains("suspension.resume()")
                        && suspend.contains("ForkTrackpadWindowPlacer.shared.reset()"),
                     "suspending the gestures forgets every half, every cycle and every pending settle")
    }

    private static func complementaryPairs(_ suite: TestSuite) {
        typealias Memory = ForkLayoutHalfMemory<Int>
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let other = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let rect = CGRect(x: 0, y: 0, width: 720, height: 900)
        var memory = Memory()
        memory.record(1, in: .left, layoutFrame: screen, frame: rect)
        memory.record(2, in: .right, layoutFrame: other, frame: rect)
        memory.record(3, in: .top, layoutFrame: screen, frame: rect)
        suite.expect(memory.complementaryPairs().isEmpty,
                     "no pair without both facing halves of one layout frame")
        memory.record(4, in: .right, layoutFrame: screen, frame: rect)
        memory.record(5, in: .bottom, layoutFrame: screen, frame: rect)
        let pairs = memory.complementaryPairs()
        suite.expect(pairs.count == 2
                        && pairs[0].first.window == 1 && pairs[0].second.window == 4
                        && pairs[1].first.window == 3 && pairs[1].second.window == 5,
                     "pairs come left then right, top then bottom")
    }

    private static func linkedBorder(_ suite: TestSuite) {
        typealias Pair = ForkLinkedPair
        let left = CGRect(x: 0, y: 25, width: 720, height: 875)
        let right = CGRect(x: 720, y: 25, width: 720, height: 875)
        let border = Pair.border(between: left, and: right, axis: .vertical, windowGap: 0)
        suite.expect(border == ForkLinkedBorder(axis: .vertical, firstEnd: 720, gap: 0,
                                                  spanStart: 25, spanEnd: 900)
                        && border?.handleRect == CGRect(x: 716, y: 25, width: 8, height: 875),
                     "two touching halves share an 8 pt handle along their whole edge")
        let gapped = Pair.border(between: CGRect(x: 0, y: 25, width: 712, height: 875),
                                 and: CGRect(x: 728, y: 25, width: 712, height: 875),
                                 axis: .vertical, windowGap: 16)
        suite.expect(gapped?.gap == 16
                        && gapped?.handleRect == CGRect(x: 708, y: 25, width: 24, height: 875),
                     "with a window gap the handle spans the gap and reaches over both edges")
        suite.expect(Pair.border(between: left, and: right, axis: .vertical, windowGap: 16) == nil
                        && Pair.border(between: left, and: right.offsetBy(dx: 2, dy: 0),
                                       axis: .vertical, windowGap: 0) != nil
                        && Pair.border(between: left, and: right.offsetBy(dx: 3, dy: 0),
                                       axis: .vertical, windowGap: 0) == nil
                        && Pair.border(between: left, and: right.offsetBy(dx: -3, dy: 0),
                                       axis: .vertical, windowGap: 0) == nil,
                     "windows link only one window gap apart, 2 pt of rounding aside")
        suite.expect(Pair.border(between: left, and: CGRect(x: 720, y: 860, width: 720, height: 40),
                                 axis: .vertical, windowGap: 0)?.spanEnd == 900
                        && Pair.border(between: left, and: CGRect(x: 720, y: 861, width: 720, height: 39),
                                       axis: .vertical, windowGap: 0) == nil,
                     "windows that barely face each other have no shared edge")
        let top = CGRect(x: 0, y: 25, width: 1440, height: 437)
        let bottom = CGRect(x: 0, y: 462, width: 1440, height: 438)
        suite.expect(Pair.border(between: top, and: bottom, axis: .horizontal, windowGap: 0)?.handleRect
                        == CGRect(x: 0, y: 458, width: 1440, height: 8),
                     "top and bottom halves share a horizontal handle")
        suite.expect(ForkLayoutComplement.isAnchored(CGRect(x: 0, y: 24, width: 1440, height: 400),
                                                       in: .bottom, of: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                       tolerance: Pair.anchorTolerance)
                        && !ForkLayoutComplement.isAnchored(CGRect(x: 0, y: 25, width: 1440, height: 400),
                                                              in: .bottom,
                                                              of: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                              tolerance: Pair.anchorTolerance),
                     "a linked half may sit up to 24 pt off its outer edge, for Terminal's text grid")
    }

    private static func linkedResize(_ suite: TestSuite) {
        typealias Resize = ForkLinkedResize
        let left = CGRect(x: 0, y: 25, width: 720, height: 875)
        let right = CGRect(x: 720, y: 25, width: 720, height: 875)
        let resize = Resize(axis: .vertical, first: left, second: right)
        let moved = resize.frames(borderAt: 900)
        suite.expect(resize.startBorder == 720
                        && moved.first == CGRect(x: 0, y: 25, width: 900, height: 875)
                        && moved.second == CGRect(x: 900, y: 25, width: 540, height: 875),
                     "one window grows by what the other gives up, outer edges fixed")
        suite.expect(resize.clampedBorder(50) == 120 && resize.clampedBorder(1400) == 1320
                        && resize.frames(borderAt: 5000).second.width == 120,
                     "neither window shrinks under 120 pt")
        let narrow = Resize(axis: .vertical, first: CGRect(x: 0, y: 25, width: 100, height: 875),
                            second: CGRect(x: 100, y: 25, width: 1340, height: 875))
        suite.expect(narrow.clampedBorder(100) == 100 && narrow.clampedBorder(20) == 100,
                     "a window already narrower than the floor can still come back to its start")

        let gapped = Resize(axis: .vertical, first: CGRect(x: 0, y: 25, width: 712, height: 875),
                            second: CGRect(x: 728, y: 25, width: 712, height: 875))
        let apart = gapped.frames(borderAt: 800)
        suite.expect(gapped.gap == 16
                        && apart.first.maxX == 800 && apart.second.minX == 816 && apart.second.maxX == 1440
                        && gapped.clampedBorder(2000) == 1440 - 120 - 16,
                     "the window gap stays the same during the whole drag")

        let vertical = Resize(axis: .horizontal, first: CGRect(x: 0, y: 25, width: 1440, height: 437),
                              second: CGRect(x: 0, y: 462, width: 1440, height: 438))
        let lowered = vertical.frames(borderAt: 600)
        suite.expect(lowered.first == CGRect(x: 0, y: 25, width: 1440, height: 575)
                        && lowered.second == CGRect(x: 0, y: 600, width: 1440, height: 300),
                     "a horizontal edge moves along y the same way")

        suite.expect(Resize.writeOrder(from: 720, to: 800) == [.second, .first]
                        && Resize.writeOrder(from: 720, to: 600) == [.first, .second],
                     "the shrinking window is always written first")
        suite.expect(Resize.resizesBeforeMoving(from: right, to: moved.second)
                        && !Resize.resizesBeforeMoving(from: left, to: moved.first),
                     "a shrinking window takes its size before its position")
    }

    private static func linkedSettle(_ suite: TestSuite) {
        let left = CGRect(x: 0, y: 25, width: 720, height: 875)
        let right = CGRect(x: 720, y: 25, width: 720, height: 875)
        let resize = ForkLinkedResize(axis: .vertical, first: left, second: right)
        let requested = resize.frames(borderAt: 900)
        suite.expect(resize.settledBorder(requested: requested, actualFirst: requested.first,
                                          actualSecond: requested.second.insetBy(dx: 0.5, dy: 0)) == nil,
                     "sizes taken as asked, rounding aside, keep the edge")
        var stubborn = requested.second
        stubborn.size.width = 700
        suite.expect(resize.settledBorder(requested: requested, actualFirst: requested.first,
                                          actualSecond: stubborn) == 740,
                     "a right window refusing to shrink (TextEdit's minimum) holds the edge")
        var rounded = requested.first
        rounded.size.width = 893
        suite.expect(resize.settledBorder(requested: requested, actualFirst: rounded,
                                          actualSecond: requested.second) == 893,
                     "a left window rounding down to its grid moves the edge to what it took")
        suite.expect(resize.settledBorder(requested: requested, actualFirst: rounded, actualSecond: stubborn) == 740,
                     "a window left larger than asked wins over one left smaller")
        let gapped = ForkLinkedResize(axis: .vertical, first: CGRect(x: 0, y: 25, width: 712, height: 875),
                                        second: CGRect(x: 728, y: 25, width: 712, height: 875))
        let asked = gapped.frames(borderAt: 1000)
        var wide = asked.second
        wide.size.width = 500
        suite.expect(gapped.settledBorder(requested: asked, actualFirst: asked.first, actualSecond: wide)
                        == 1440 - 500 - 16,
                     "the edge held by the right window leaves the window gap before it")
    }

    private static func linkedOrder(_ suite: TestSuite) {
        typealias Order = ForkLinkedResizeOrder
        func window(_ number: CGWindowID, _ bounds: CGRect, layer: Int = 0) -> Order.Window {
            Order.Window(number: number, layer: layer, bounds: bounds)
        }
        let strip = CGRect(x: 716, y: 25, width: 8, height: 875)
        let left = window(10, CGRect(x: 0, y: 25, width: 720, height: 875))
        let right = window(11, CGRect(x: 720, y: 25, width: 720, height: 875))
        let handle = window(99, strip)
        let cover = window(12, CGRect(x: 600, y: 100, width: 300, height: 300))
        let elsewhere = window(13, CGRect(x: 0, y: 500, width: 200, height: 200))
        func place(_ windows: [Order.Window]) -> Order.Placement {
            Order.placement(handle: 99, strip: strip, first: 10, second: 11, in: windows)
        }
        suite.expect(place([handle, left, right]) == .keep
                        && place([handle, elsewhere, right, left]) == .keep,
                     "a handle just above the front window of its pair stays put")
        suite.expect(place([left, handle, right]) == .above(10) && place([left, right]) == .above(10),
                     "a handle under its pair, or not shown yet, goes just above the front one")
        suite.expect(place([handle, cover, right, left]) == .above(11)
                        && place([cover, right, left]) == .above(11),
                     "a third window over the edge keeps its clicks")
        suite.expect(place([handle, window(14, strip, layer: 25), left, right]) == .keep,
                     "a menu or panel layer above does not count as covering the edge")
        suite.expect(place([handle, left]) == .hidden && place([right]) == .hidden,
                     "no handle while either window is off this Space or hidden")
        suite.expect(Order.frontSide(first: 10, second: 11, in: [right, left]) == .second
                        && Order.frontSide(first: 10, second: 11, in: [left, right]) == .first
                        && Order.frontSide(first: 10, second: 11, in: []) == .first,
                     "Command resizes the front window of the pair alone, the first when unknown")
    }

    private static func linkedWiring(_ suite: TestSuite) {
        let key = ForkDefaultsKey.linkedResizeEnabled
        suite.expect(ForkDefaults.registered[key] as? Bool == false,
                     "linked windows stay off by default")
        suite.expect(ForkDefaults.backupKeys.contains(key),
                     "the linked windows switch travels with the settings backup")
        let page = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadSettings.swift")
        let linkedCard = page.components(separatedBy: "private var linkedSection: some View {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(linkedCard.contains("linkedResizeEnabled.toggle()")
                        && linkedCard.contains("text.linkedEnable") && linkedCard.contains("text.linkedCaption")
                        && linkedCard.contains("ForkGestures.sync()"),
                     "the linked windows card switches them, with its caption, and syncs")

        let gestures = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkGestures.swift")
        let sync = gestures.components(separatedBy: "static func sync()").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        let running = sync.components(separatedBy: "if canRun && allowed {").dropFirst().first?
            .components(separatedBy: "} else {").first ?? ""
        suite.expect(running.contains("""
            ForkLinkedResizeService.shared.setEnabled(
                            UserDefaults.standard.bool(forKey: ForkDefaultsKey.linkedResizeEnabled))
            """),
                     "linked windows run only with the trackpad gestures and their own switch")
        let suspend = gestures.components(separatedBy: "static func suspend()").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(suspend.contains("ForkLinkedResizeService.shared.setEnabled(false)")
                        && (sync.components(separatedBy: "} else {").dropFirst().first ?? "")
                            .contains("ForkLinkedResizeService.shared.setEnabled(false)"),
                     "stopping or suspending the gestures removes the linked handles")
        let service = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadWindowPlacer.swift")
        let half = service.components(separatedBy: "private func applyHalf(").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(half.contains("ForkLinkedResizeService.shared.halvesChanged()"),
                     "a remembered half wakes the linked handles")

        let pairs = service.components(separatedBy: "func linkedWindowPairs()").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(pairs.contains("where frame == nil && now >= halfSettleDeadlines[entry.window.key, default: 0]")
                        && pairs.contains("forgetHalf(entry.window.key)")
                        && service.contains("halfSettleDeadlines[window.key] = ProcessInfo.processInfo.systemUptime + Self.halfSettleWindow"),
                     "a half left by hand is forgotten once settled, so the handles stop reading")
        let linked = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkLinkedResizeService.swift")
        let refresh = linked.components(separatedBy: "private func refresh()").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        let candidates = refresh.range(of: "guard ForkTrackpadWindowPlacer.shared.hasLinkCandidates")
        let reads = refresh.range(of: "ForkTrackpadWindowPlacer.shared.linkedWindowPairs()")
        suite.expect(candidates != nil && reads != nil
                        && candidates!.lowerBound < reads!.lowerBound
                        && refresh.contains("stopTimer()"),
                     "without a remembered pair the handles read nothing and the timer stops")
        let move = linked.components(separatedBy: "private func move(to border:").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        let sizeOnly = move.range(of: "ForkLinkedResizeService.setSize(pick(requested, shrinking).size")
        let both = move.range(of: "writeFrames(target, of: pair, order: [shrinking, growing])")
        suite.expect(sizeOnly != nil && both != nil && sizeOnly!.lowerBound < both!.lowerBound,
                     "the shrinking window's size is written and read back before anything else moves")
        suite.expect(linked.contains("guard event.keyCode == UInt16(kVK_Escape)")
                        && linked.contains("self?.cancelDrag()")
                        && linked.contains("NSEvent.modifierFlags.contains(.command) { unlinked = true }"),
                     "Escape puts both windows back and Command unlinks them")

        let all = AppLanguage.allCases.map(FeatureStrings.forkTrackpadGestures)
        suite.expect(all.allSatisfy { !$0.linkedEnable.isEmpty && !$0.linkedCaption.isEmpty }
                        && Set(all.map(\.linkedCaption)).count >= 14,
                     "linked windows strings exist and are translated in every language")
    }

    private static func gestureGroups(_ suite: TestSuite) {
        typealias Group = ForkTrackpadGestureGroup
        let grouped = Group.grouped()
        let shown = grouped.flatMap { $0.entries.map(\.action) }
        suite.expect(shown.count == ForkTrackpadGestureCatalog.allEntries.count
                        && Set(shown) == Set(ForkTrackpadGestureCatalog.allEntries.map(\.action))
                        && Set(shown) == Set(Action.allCases),
                     "every gesture, a held key's included, shows exactly once on the Trackpad page")
        suite.expect(grouped.map(\.group) == [.grid4, .grid6, .titlebar, .pinch, .tap, .shift, .dock],
                     "the groups read 4-zone grid, 6-zone grid, title bar, pinch, tap, Shift, then Dock")
        func group(_ action: Action) -> Group? {
            ForkTrackpadGestureCatalog.entry(for: action).map(Group.of)
        }
        suite.expect(group(.leftHalf) == .grid4 && group(.topHalf) == .grid4
                        && group(.maximize) == .titlebar && group(.minimize) == .titlebar,
                     "the halves go with the 4-zone grid, maximize and minimize with the title bar swipes")
        suite.expect(group(.topLeftQuarter) == .grid4 && group(.bottomRightQuarter) == .grid4,
                     "a diagonal goes with the 4-zone grid")
        suite.expect(group(.leftThird) == .grid6 && group(.topCenterSixth) == .grid6
                        && group(.bottomRightTwoSixths) == .grid6
                        && group(.marginMaximize) == .shift && group(.restorePlacement) == .shift,
                     "Option's thirds and sixths go with the 6-zone grid, Shift's gestures with Shift")
        suite.expect(ForkTrackpadGestureCatalog.entry(for: .leftTwoThirds)?.symbols == "⌥ ← →"
                        && ForkTrackpadGestureCatalog.entry(for: .minimizeAllWindows)?.symbols == "⇧ ↓"
                        && ForkTrackpadGestureCatalog.entry(for: .close)?.symbols == "⤡",
                     "a card shows its held key before the movement")
        typealias Keys = ForkTrackpadModifierKeys
        suite.expect(Keys(flags: [.maskAlternate, .maskAlphaShift]) == .option
                        && Keys(flags: [.maskShift, .maskCommand]) == [.shift, .command]
                        && Keys([.command, .control, .option]).symbols == "⌃⌥⌘",
                     "held keys read ⌃ ⌥ ⇧ ⌘ only, written in macOS order")
        let suiteName = "fork.tests.modifierKeys"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        suite.expect(Keys.current(defaults) == (Keys.option, Keys.shift),
                     "the grid starts on Option and the stronger gestures on Shift")
        defaults.set(Keys([.control, .command]).rawValue, forKey: ForkDefaultsKey.gridModifierKeys)
        defaults.set(Keys.option.rawValue, forKey: ForkDefaultsKey.strongerModifierKeys)
        suite.expect(Keys.current(defaults) == (Keys([.control, .command]), Keys.option),
                     "any combination of keys can be chosen for either")
        defaults.set(Keys.option.rawValue, forKey: ForkDefaultsKey.gridModifierKeys)
        suite.expect(Keys.current(defaults) == (Keys.option, Keys.shift),
                     "two identical choices fall back to the defaults rather than collide")
        defaults.set(0, forKey: ForkDefaultsKey.strongerModifierKeys)
        suite.expect(Keys.current(defaults).stronger == .shift, "an empty choice falls back to its default")
        defaults.removePersistentDomain(forName: suiteName)
        for entry in ForkTrackpadGestureCatalog.modifierEntries where entry.modifier == .option {
            guard case let .swipes(steps) = entry.triggers[0] else { continue }
            let chain = ForkTrackpadGestureSequence.Chain([steps[0]])
            let first = ForkTrackpadGestureSequence.resolveGrid(
                horizontal: chain.horizontal.map { (column: $0 == .left ? 0 : 2, span: 1) },
                vertical: chain.vertical.map { (edge: $0, span: 1) })
            suite.expect(first != nil, "\(entry.action)'s first ⌥ step already names a zone")
        }
        suite.expect(group(.toggleFullScreen) == .pinch && group(.quitWindowApp) == .pinch
                        && group(.centerReduced) == .tap && group(.quitApp) == .dock,
                     "pinches, the double tap and the Dock each have their group")
        let chained = ForkTrackpadGestureCatalog.Entry(action: .topLeftQuarter, target: .titlebar,
                                                         triggers: [.swipes([.up, .left])])
        suite.expect(Group.of(chained) == .grid4,
                     "two different directions chained go with the quarters too")

        let pinches = grouped.first { $0.group == .pinch }?.entries ?? []
        let allOff = Group.setting(pinches, enabled: false, in: [.leftHalf])
        suite.expect(allOff == Set(pinches.map(\.action)).union([.leftHalf])
                        && Group.allDisabled(pinches, in: allOff)
                        && !Group.allDisabled(pinches, in: [.close])
                        && Group.setting(pinches, enabled: true, in: allOff) == [.leftHalf],
                     "a group switches all its gestures and only them")
    }

    private static func disabledGestureStorage(_ suite: TestSuite) {
        typealias Stored = ForkTrackpadDisabledGestures
        suite.expect(Stored.storageValue([.close, .leftHalf]) == "close,leftHalf"
                        && Stored.actions(from: "leftHalf, close,notAGesture,") == [.leftHalf, .close]
                        && Stored.actions(from: "").isEmpty,
                     "switched-off gestures store as sorted raw values, unknown ones dropped")
        let key = ForkDefaultsKey.disabledGestures
        suite.expect(ForkDefaults.registered[key] as? String == ""
                        && ForkDefaults.backupKeys.contains(key),
                     "every gesture starts on, and the choice travels with the settings backup")
        let service = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadGestureService.swift")
        let start = service.components(separatedBy: "func start() {").dropFirst().first ?? ""
        suite.expect(start.hasPrefix("\n        machine.configuration.disabledActions = ForkTrackpadDisabledGestures.current"),
                     "the machine takes the switched-off gestures on every sync, before anything else")
        let page = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadSettings.swift")
        suite.expect(page.contains("disabledStorage = ForkTrackpadDisabledGestures.storageValue(actions)\n        ForkGestures.sync()")
                        && page.contains("isEnabled: !disabled.contains(entry.action)"),
                     "a card click stores the gesture's state and syncs the service")

        suite.expect(ForkTrackpadGestureTrigger.swipes([.down, .down]).symbols == "↓ ↓"
                        && ForkTrackpadGestureTrigger.swipes([.upLeft]).symbols == "↖"
                        && ForkTrackpadGestureTrigger.pinches([.in, .in]).symbols == "⤡ ⤡"
                        && ForkTrackpadGestureTrigger.pinches([.out]).symbols == "⤢"
                        && ForkTrackpadGestureTrigger.doubleTap.symbols == "••",
                     "each card writes what the fingers do")

        let text = FeatureStrings.forkTrackpadGestures(.enUS)
        let layoutText = FeatureStrings.windowLayout(.enUS)
        suite.expect(ForkTrackpadGestureTitle.title(of: .leftHalf, text: text, layoutText: layoutText)
                        == WindowLayoutAction.leftHalf.title(layoutText)
                        && ForkTrackpadGestureTitle.title(of: .toggleFullScreen, text: text, layoutText: layoutText)
                        == WindowLayoutAction.fullScreen.title(layoutText)
                        && ForkTrackpadGestureTitle.title(of: .quitApp, text: text, layoutText: layoutText)
                        == text.actionQuitApp,
                     "a gesture shows its placement's own name, or its own when it has none")
        let all = AppLanguage.allCases.map(FeatureStrings.forkTrackpadGestures)
        let names = all.map { strings in
            Action.allCases.map { ForkTrackpadGestureTitle.title(of: $0, text: strings,
                                                                   layoutText: layoutText) }
        }
        suite.expect(names.allSatisfy { Set($0).count == Action.allCases.count }
                        && all.allSatisfy { !$0.modeTrackpad.isEmpty && !$0.groupDockCaption.isEmpty
                            && !$0.actionCenter.isEmpty && !$0.disableAll.isEmpty },
                     "every gesture has a distinct name, and the page reads in every language")
        suite.expect(Set(all.map(\.groupGrid4Caption)).count >= 14
                        && Set(all.map(\.groupGrid6Caption)).count >= 14
                        && all.allSatisfy { !$0.cancelEnabledTitle.isEmpty && !$0.actionTopLeftTwoSixths.isEmpty } && Set(all.map(\.activate)).count >= 14,
                     "the Trackpad page is translated, not copied from English")
    }

    private static func tuningLadders(_ suite: TestSuite) {
        typealias Tuning = ForkTrackpadTuning
        let machine = Machine.Configuration()
        suite.expect(Tuning.swipeSensitivity.defaultValue == machine.swipeThreshold
                        && Tuning.pinchSensitivity.defaultValue == machine.pinchThreshold
                        && Tuning.stepPause.defaultValue == machine.stepPause
                        && Tuning.cancelDelay.defaultValue == machine.cancelTimeout
                        && Tuning.centerSize.defaultValue == ForkTrackpadCenter.defaultScale
                        && Tuning.titlebarBand.defaultValue == 40,
                     "every setting starts on the value the gestures used before they could be tuned")
        func rises(_ steps: [Double]) -> Bool { zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 } }
        func falls(_ steps: [Double]) -> Bool { zip(steps, steps.dropFirst()).allSatisfy { $0 > $1 } }
        suite.expect(rises(Tuning.centerSize.steps) && rises(Tuning.stepPause.steps)
                        && rises(Tuning.cancelDelay.steps) && rises(Tuning.titlebarBand.steps),
                     "sizes, pauses, delays and the band grow from left to right")
        suite.expect(falls(Tuning.swipeSensitivity.steps) && falls(Tuning.pinchSensitivity.steps),
                     "more sensitive, on the right, means a shorter travel")
        suite.expect(Tuning.stepPause.steps.max()! < Tuning.cancelDelay.steps.min()!,
                     "every step pause stays under every cancel delay")
        suite.expect(Tuning.allCases.allSatisfy { $0.steps.count >= 5 && $0.steps.indices.contains($0.defaultStep) }
                        && Tuning.centerSize.steps.allSatisfy { ForkTrackpadCenter.scaleRange.contains($0) },
                     "each setting has at least five notches, its default among them")
        suite.expect(Tuning.centerSize.value(atStep: -3) == Tuning.centerSize.steps.first
                        && Tuning.centerSize.value(atStep: 99) == Tuning.centerSize.steps.last
                        && Tuning.stepPause.value(atStep: 3) == 0.25,
                     "a stored step off the ladder lands on its nearest end")
        var configuration = Machine.Configuration()
        Tuning.apply(to: &configuration, cancelEnabled: true) { $0.steps.last! }
        suite.expect(configuration.swipeThreshold == 3 && configuration.pinchThreshold == 0.012
                        && configuration.stepPause == 0.5 && configuration.cancelTimeout == 2,
                     "the tuned values reach the gesture machine")
        var endless = Machine.Configuration()
        Tuning.apply(to: &endless, cancelEnabled: false) { $0.defaultValue }
        suite.expect(endless.cancelTimeout == .infinity
                        && ForkDefaults.registered[ForkDefaultsKey.cancelEnabled] as? Bool == true
                        && ForkDefaults.backupKeys.contains(ForkDefaultsKey.cancelEnabled),
                     "the cancel can be switched off, starts on, and travels with the backup")
        suite.expect(Set(Tuning.allCases.map(\.key)).count == Tuning.allCases.count
                        && Tuning.allCases.allSatisfy {
                            ForkDefaults.registered[$0.key] as? Int == $0.defaultStep
                                && ForkDefaults.backupKeys.contains($0.key)
                        },
                     "each setting has its own key, registered on its default step and backed up")
        let previous = UserDefaults.standard.object(forKey: Tuning.stepPause.key)
        UserDefaults.standard.set(4, forKey: Tuning.stepPause.key)
        let tuned = Tuning.stepPause.current
        UserDefaults.standard.removeObject(forKey: Tuning.stepPause.key)
        let fallback = Tuning.stepPause.current
        if let previous { UserDefaults.standard.set(previous, forKey: Tuning.stepPause.key) }
        suite.expect(tuned == 0.3 && fallback == Tuning.stepPause.defaultValue,
                     "the stored step is read back, a missing one as the default")
    }

    private static func tuningWiring(_ suite: TestSuite) {
        for key in [ForkDefaultsKey.previewEnabled, ForkDefaultsKey.hapticsEnabled] {
            suite.expect(ForkDefaults.registered[key] as? Bool == true
                            && ForkDefaults.backupKeys.contains(key),
                         "the preview and haptic switches start on and are backed up (\(key))")
        }
        let service = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadGestureService.swift")
        let start = service.components(separatedBy: "func start() {").dropFirst().first?
            .components(separatedBy: "if let port").first ?? ""
        suite.expect(start.contains("ForkTrackpadTuning.apply(to: &machine.configuration)")
                        && start.contains("titlebarBandHeight = ForkTrackpadTuning.titlebarBand.current")
                        && start.contains("previewEnabled = UserDefaults.standard.bool(forKey: ForkDefaultsKey.previewEnabled)")
                        && start.contains("hapticsEnabled = UserDefaults.standard.bool(forKey: ForkDefaultsKey.hapticsEnabled)"),
                     "every sync hands the tuned values to the machine and the title bar test")
        suite.expect(service.contains("Self.titlebarWindow(at: input.location, bandHeight: titlebarBandHeight)")
                        && service.contains("bandHeight: bandHeight)"),
                     "the title bar test uses the tuned band")
        suite.expect(service.contains("case .haptic(.step):\n                guard hapticsEnabled else { break }")
                        && service.contains("case .haptic(.cancel):\n                guard hapticsEnabled else { break }")
                        && service.contains("guard previewEnabled else { break }\n                showPreview(preview)")
                        && service.contains("case .hidePreview:\n                ForkTrackpadGesturePreview.shared.hide()"),
                     "haptics and the preview follow their switches, and a shown preview always goes away")
        suite.expect(service.contains("centerScale: ForkTrackpadTuning.centerSize.current)"),
                     "the live preview shows the tuned center size")
        let layout = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadWindowPlacer.swift")
        suite.expect(layout.contains("scale: ForkTrackpadTuning.centerSize.current).integral"),
                     "a double tap centers the window at the tuned size")

        let page = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadSettings.swift")
        let slider = page.components(separatedBy: "private struct ForkTrackpadStepSlider").dropFirst().first ?? ""
        suite.expect(slider.contains("step: 1) {") && slider.contains("minimumValueLabel: {\n            Text(lowLabel)")
                        && slider.contains("maximumValueLabel: {\n            Text(highLabel)")
                        && slider.contains(".onChange(of: step) { _, _ in ForkGestures.sync() }"),
                     "settings are notches between two words, synced as they move")
        let tapGroup = page.components(separatedBy: "if group == .tap {").dropFirst().first?
            .components(separatedBy: "} header:").first ?? ""
        suite.expect(tapGroup.contains("centerSizeControl")
                        && page.contains("tuning: .centerSize,\n                                     lowLabel: text.sizeSmall, highLabel: text.sizeLarge")
                        && page.contains("centerScale: centerScale,")
                        && page.contains("ForkTrackpadPreviewContent(.action(action), centerScale: centerScale)"),
                     "the center size sits under the double tap, and its card redraws with it")
        let advanced = page.components(separatedBy: "private var advancedSection: some View {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(advanced.contains("DisclosureGroup(isExpanded: $showsAdvanced)")
                        && [".swipeSensitivity", ".pinchSensitivity", ".stepPause", ".cancelDelay", ".titlebarBand"]
                            .allSatisfy { advanced.contains("tuning: \($0)") }
                        && advanced.contains("Button(text.resetDefaults, action: resetAdvanced)"),
                     "the advanced settings fold away, with every tuned value and a way back")

        let all = AppLanguage.allCases.map(FeatureStrings.forkTrackpadGestures)
        suite.expect(all.allSatisfy { !$0.centerSizeTitle.isEmpty && !$0.sizeSmall.isEmpty && !$0.moreSensitive.isEmpty
                                        && !$0.hapticsDetail.isEmpty && $0.sizeSmall != $0.sizeLarge
                                        && $0.lessSensitive != $0.moreSensitive && $0.shorter != $0.longer
                                        && $0.bandThin != $0.bandTall }
                        && Set(all.map(\.sensitivityCaption)).count >= 14
                        && Set(all.map(\.advancedTitle)).count >= 13,
                     "the tuning strings exist in every language, both ends of each scale told apart")
    }

    private static func emptyTrash(_ suite: TestSuite) {
        typealias Sequence = ForkTrackpadGestureSequence
        suite.expect(Sequence.resolve(pinches: [.in], on: .dockTrash) == .emptyTrash
                        && Sequence.resolve(pinches: [.in], on: .dockApp) == .quitApp
                        && Sequence.resolve(pinches: [.out], on: .dockTrash) == nil
                        && Sequence.resolve(pinches: [.in, .in], on: .dockTrash) == nil
                        && Sequence.resolveDoubleTap(on: .dockTrash) == nil,
                     "pinching in on the Trash empties it, the same move as quitting an app")
        let entry = ForkTrackpadGestureCatalog.entry(for: .emptyTrash)
        suite.expect(entry?.targets == [.dockTrash] && entry?.triggers == [.pinches([.in])]
                        && entry.map(ForkTrackpadGestureGroup.of) == .dock
                        && Action.emptyTrash.rawValue == "emptyTrash" && Action.emptyTrash.layoutAction == nil,
                     "emptying the Trash has its card with the Dock gestures, and can be switched off")
        suite.expect(ForkTrackpadPreviewContent(.action(.emptyTrash)) == .emptyTrash
                        && ForkTrackpadPreviewContent.emptyTrash.isAtPointer,
                     "its preview is the red light with the Trash, on the pointer")
        suite.expect(ForkTrackpadDock.emptyTrashFlags == [.maskCommand, .maskShift]
                        && !ForkTrackpadDock.emptyTrashFlags.contains(.maskAlternate),
                     "the Trash is emptied with Finder's shortcut that asks first, never the one that skips it")
        let text = FeatureStrings.forkTrackpadGestures(.fr)
        suite.expect(ForkTrackpadGestureTitle.title(of: .emptyTrash, text: text,
                                                      layoutText: FeatureStrings.windowLayout(.fr))
                        == "Vider la Corbeille"
                        && Set(AppLanguage.allCases.map { FeatureStrings.forkTrackpadGestures($0).actionEmptyTrash }).count >= 13,
                     "emptying the Trash is named in every language")

        let tap = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadGestureService.swift")
        let commit = tap.components(separatedBy: "case .commit(let rawAction):").dropFirst().first?
            .components(separatedBy: "case .haptic").first ?? ""
        suite.expect(commit.contains("case (.dockTrash?, .emptyTrash):\n                    Self.emptyTrash()")
                        && commit.contains("where action.isWindowAction:"),
                     "only a gesture begun on the Trash empties it, and no window ever gets that action")
        let body = tap.components(separatedBy: "private static func emptyTrash() {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(body.contains("withBundleIdentifier: ForkTrackpadDock.finderBundleIdentifier")
                        && body.contains("finder.activate(options: [])")
                        && body.contains("virtualKey: CGKeyCode(kVK_Delete)")
                        && body.contains("event.flags = ForkTrackpadDock.emptyTrashFlags")
                        && body.contains("event.postToPid(finder.processIdentifier)")
                        && !body.contains("removeItem") && !body.contains("NSAppleScript"),
                     "Finder empties the Trash itself, brought forward so its question shows")
        suite.expect(tap.contains("appIcon: preview == .action(.emptyTrash)\n                                                    ? NSImage(named: NSImage.trashFullName)"),
                     "the preview shows the Trash's icon")
    }

    private static func finderWindows(_ suite: TestSuite) {
        typealias Sequence = ForkTrackpadGestureSequence
        suite.expect(Sequence.resolve(swipes: [.up], on: .dockApp) == .showAppWindows
                        && Sequence.resolve(swipes: [.up], on: .dockFinder) == .showAppWindows
                        && Sequence.resolve(swipes: [.down], on: .dockApp) == nil
                        && Sequence.resolve(swipes: [.up, .up], on: .dockFinder) == nil
                        && Sequence.resolve(swipes: [.upLeft], on: .dockApp) == nil
                        && Sequence.resolve(swipes: [.up], on: .dockTrash) == nil
                        && Sequence.accepts(.swipe, on: .dockApp) && Sequence.accepts(.swipe, on: .dockFinder)
                        && !Sequence.accepts(.swipe, on: .dockFinder,
                                             disabled: [.showAppWindows, .showNextWindow, .showPreviousWindow])
                        && Sequence.accepts(.swipe, on: .dockFinder, disabled: [.showAppWindows])
                        && !Sequence.accepts(.swipe, on: .dockTrash),
                     "swiping up on a running app's icon, Finder's included, brings its windows back")
        let entry = ForkTrackpadGestureCatalog.entry(for: .showAppWindows)
        suite.expect(entry?.targets == [.dockApp, .dockFinder] && entry?.triggers == [.swipes([.up])]
                        && entry.map(ForkTrackpadGestureGroup.of) == .dock
                        && Action.showAppWindows.rawValue == "showAppWindows"
                        && ForkTrackpadPreviewContent(.action(.showAppWindows)) == .showApp
                        && ForkTrackpadPreviewContent.showApp.isAtPointer,
                     "an app's windows have one card with the Dock gestures, and preview as its icon")
        suite.expect(Sequence.resolve(pinches: [.in], on: .dockApp) == .quitApp
                        && Sequence.resolve(pinches: [.in], on: .dockFinder) == nil,
                     "a pinch still quits an app from its icon, and still never Finder")

        suite.expect(Sequence.resolve(swipes: [.right], on: .dockApp) == .showNextWindow
                        && Sequence.resolve(swipes: [.right], on: .dockFinder) == .showNextWindow
                        && Sequence.resolve(swipes: [.left], on: .dockApp) == .showPreviousWindow
                        && Sequence.resolve(swipes: [.left], on: .dockFinder) == .showPreviousWindow
                        && Sequence.resolve(swipes: [.right, .right], on: .dockApp) == nil,
                     "swiping sideways on an app's icon, Finder's included, chains to its next or previous window")
        let nextEntry = ForkTrackpadGestureCatalog.entry(for: .showNextWindow)
        let previousEntry = ForkTrackpadGestureCatalog.entry(for: .showPreviousWindow)
        suite.expect(nextEntry?.targets == [.dockApp, .dockFinder] && nextEntry?.triggers == [.swipes([.right])]
                        && previousEntry?.targets == [.dockApp, .dockFinder]
                        && previousEntry?.triggers == [.swipes([.left])]
                        && nextEntry.map(ForkTrackpadGestureGroup.of) == .dock
                        && previousEntry.map(ForkTrackpadGestureGroup.of) == .dock
                        && ForkTrackpadPreviewContent(.action(.showNextWindow)) == .showApp
                        && ForkTrackpadPreviewContent(.action(.showPreviousWindow)) == .showApp,
                     "chaining windows has its own card with the Dock gestures, and previews as the app's icon")

        let tap = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadGestureService.swift")
        suite.expect(tap.contains("case (.dockApp(let pid)?, .showAppWindows), (.dockFinder(let pid)?, .showAppWindows):\n                    Self.showAppWindows(pid: pid)"),
                     "only a gesture begun on an app's icon calls its windows back")
        suite.expect(tap.contains("case (.dockApp(let pid)?, .showNextWindow), (.dockFinder(let pid)?, .showNextWindow):\n                    showAdjacentWindow(pid: pid, forward: true)")
                        && tap.contains("case (.dockApp(let pid)?, .showPreviousWindow), (.dockFinder(let pid)?, .showPreviousWindow):\n                    showAdjacentWindow(pid: pid, forward: false)"),
                     "only a gesture begun on an app's icon chains its windows")
        let chain = tap.components(separatedBy: "private func showAdjacentWindow(pid: pid_t, forward: Bool) {")
            .dropFirst().first?.components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(chain.contains("Self.bool($0, kAXMinimizedAttribute) != true")
                        && chain.contains("AXWindowResolver.windowID(for: window)")
                        && chain.contains(".sorted { $0.id < $1.id }")
                        && chain.contains("guard let only = ordered.first else {\n                Self.showAppWindows(pid: pid)")
                        && chain.contains("chainedWindow[pid].flatMap")
                        && chain.contains("ForkTrackpadWindowChain.nextIndex(current: currentIndex, count: ordered.count,")
                        && chain.contains("chainedWindow[pid] = next.id")
                        && chain.contains("kAXRaiseAction") && chain.contains("kAXMainAttribute as CFString")
                        && chain.contains("kAXFocusedAttribute as CFString"),
                     "chaining skips minimized windows, orders them by ID, remembers its place, simply raises "
                        + "the one left alone, and otherwise raises, focuses and marks the next one main")
        let body = tap.components(separatedBy: "private static func showAppWindows(pid: pid_t) {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        let unminimize = body.range(of: "AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)")
        let reopen = body.range(of: "NSWorkspace.shared.openApplication(at: url, configuration: configuration)")
        suite.expect(body.contains("guard pid != ProcessInfo.processInfo.processIdentifier,")
                        && body.contains("running.unhide()")
                        && unminimize != nil && reopen != nil && unminimize!.lowerBound < reopen!.lowerBound
                        && body.contains("guard minimized.isEmpty, let url = running.bundleURL else {\n            _ = running.activate(options: [])")
                        && !body.contains("terminate"),
                     "every minimized window comes back, a hidden app shows, and with nothing to bring back the app reopens")
    }

    private static func minimizedWindows(_ suite: TestSuite) {
        typealias Sequence = ForkTrackpadGestureSequence
        typealias Dock = ForkTrackpadDock
        suite.expect(Sequence.resolve(swipes: [.up], on: .dockMinimizedWindow) == .restoreMinimizedWindow
                        && Sequence.resolve(pinches: [.in], on: .dockMinimizedWindow) == .closeMinimizedWindow
                        && Sequence.resolve(pinches: [.out], on: .dockMinimizedWindow) == nil
                        && Sequence.resolve(pinches: [.in, .in], on: .dockMinimizedWindow) == nil
                        && Sequence.resolve(swipes: [.down], on: .dockMinimizedWindow) == nil
                        && Sequence.resolveDoubleTap(on: .dockMinimizedWindow) == nil,
                     "on a minimized window's thumbnail, swiping up reopens it and pinching in closes it")
        let thumbnail = ForkTrackpadAXNode(role: "AXDockItem", subrole: "AXMinimizedWindowDockItem")
        suite.expect(Dock.evaluate(item: thumbnail, isRunning: false, itemURL: nil, itemBundleIdentifier: nil,
                                   itemTitle: "notes.md", runningApps: [], ownPID: 1)
                        == .minimizedWindow(title: "notes.md"),
                     "a minimized window's thumbnail is a target, known by its title")
        let windows = [Dock.MinimizedWindow(pid: 10, index: 0, title: "notes.md"),
                       Dock.MinimizedWindow(pid: 11, index: 2, title: "Untitled"),
                       Dock.MinimizedWindow(pid: 12, index: 0, title: "Untitled")]
        suite.expect(Dock.minimizedWindow(titled: "notes.md", among: windows) == windows[0]
                        && Dock.minimizedWindow(titled: "Untitled", among: windows) == nil
                        && Dock.minimizedWindow(titled: "gone.txt", among: windows) == nil
                        && Dock.minimizedWindow(titled: "", among: windows) == nil
                        && Dock.minimizedWindow(titled: nil, among: windows) == nil,
                     "a thumbnail names its window only when one minimized window bears that title")
        for action in [Action.restoreMinimizedWindow, .closeMinimizedWindow] {
            let entry = ForkTrackpadGestureCatalog.entry(for: action)
            suite.expect(entry?.targets == [.dockMinimizedWindow]
                            && entry.map(ForkTrackpadGestureGroup.of) == .dock && action.layoutAction == nil,
                         "\(action) has its card with the Dock gestures")
        }
        suite.expect(ForkTrackpadPreviewContent(.action(.restoreMinimizedWindow)) == .showApp
                        && ForkTrackpadPreviewContent(.action(.closeMinimizedWindow)) == .light(.close),
                     "a thumbnail previews as its app's icon to reopen, as the red light to close")
        let text = FeatureStrings.forkTrackpadGestures(.fr)
        let layoutText = FeatureStrings.windowLayout(.fr)
        suite.expect(ForkTrackpadGestureTitle.title(of: .showAppWindows, text: text, layoutText: layoutText)
                        == "Ramener les fenêtres de l’app"
                        && ForkTrackpadGestureTitle.title(of: .restoreMinimizedWindow, text: text, layoutText: layoutText)
                        == "Rouvrir la fenêtre réduite"
                        && ForkTrackpadGestureTitle.title(of: .closeMinimizedWindow, text: text, layoutText: layoutText)
                        == "Fermer la fenêtre réduite"
                        && Set(AppLanguage.allCases.map { FeatureStrings.forkTrackpadGestures($0).actionCloseMinimizedWindow }).count >= 13,
                     "the Dock window gestures are named in every language")

        let tap = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadGestureService.swift")
        suite.expect(tap.contains("case .minimizedWindow(let title)?:\n                guard let item = dockHit?.item else { break }\n                target = .dockMinimizedWindow(item: item, window: Self.minimizedWindow(titled: title))")
                        && tap.contains("case (.dockMinimizedWindow(let item, _)?, .restoreMinimizedWindow):\n                    AXUIElementPerformAction(item, kAXPressAction as CFString)")
                        && tap.contains("case (.dockMinimizedWindow(_, let window?)?, .closeMinimizedWindow):\n                    Self.closeMinimizedWindow(window.element)"),
                     "reopening presses the thumbnail as a click would; closing needs the one window it names")
        let close = tap.components(separatedBy: "private static func closeMinimizedWindow(_ window: AXUIElement) {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(close.contains("guard bool(window, kAXMinimizedAttribute) == true,")
                        && close.contains("element(window, kAXCloseButtonAttribute)")
                        && close.contains("AXUIElementPerformAction(button, kAXPressAction as CFString)")
                        && !close.contains("terminate"),
                     "closing presses the window's own red button, only while it is still minimized, and never quits")
        let find = tap.components(separatedBy: "private static func minimizedWindow(titled title: String?)").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(find.contains("app.activationPolicy == .regular && app.processIdentifier != ownPID")
                        && find.contains("AXUIElementSetMessagingTimeout(element, hitTestTimeout)")
                        && find.contains("ForkTrackpadDock.minimizedWindow(titled: title, among: candidates)"),
                     "the window behind a thumbnail is looked for in other apps, with a short timeout")
    }

    private static func coveredDock(_ suite: TestSuite) {
        typealias Window = MouseAppExceptionSupport.Window
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let dock = Window(frame: screen, layer: 20, processID: 898)
        // What a screenshot session leaves: a full-screen window above the
        // Dock that the window server calls opaque, and that lets input through.
        let screenshot = Window(frame: screen, layer: 24, processID: 10114)
        let point = CGPoint(x: 309, y: 865)
        func owns(_ windows: [Window], accessibility: pid_t?) -> Bool {
            DockClickSupport.dockOwnsPoint(point, windows: windows, dockProcessID: 898, dockLayer: 20,
                                           ownProcessID: 1, accessibilityHitProcessID: { accessibility })
        }
        suite.expect(owns([screenshot, dock], accessibility: 898)
                        && !owns([screenshot, dock], accessibility: 10114)
                        && !owns([screenshot, dock], accessibility: nil)
                        && owns([dock], accessibility: nil),
                     "a window over the Dock is settled by Accessibility: an overlay letting input through keeps the Dock")
        let tap = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadGestureService.swift")
        let hit = tap.components(separatedBy: "private static func dockItem(at point: CGPoint)").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(hit.contains("accessibilityHitProcessID: {\n                                                 Self.accessibilityProcessID(at: point)\n                                             })")
                        && !hit.contains("accessibilityHitProcessID: { nil }"),
                     "Dock gestures ask Accessibility when a window seems to cover the Dock, as Dock clicks do")
        let lookup = tap.components(separatedBy: "static func accessibilityProcessID(at point: CGPoint)").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(lookup.contains("AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),")
                        && lookup.contains("AXUIElementGetPid(element, &pid)")
                        && !tap.contains("AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide()"),
                     "the Dock lookup asks Accessibility like Dock clicks do, never setting a timeout on the system-wide element")
    }

    private static func windowStack(_ suite: TestSuite) {
        typealias Stack = ForkTrackpadWindowStack
        let own: pid_t = 1
        let point = CGPoint(x: 500, y: 20)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let dockOverlay = Stack.Window(pid: 7, bounds: screen, alpha: 1, layer: 20)
        let finder = Stack.Window(pid: 42, bounds: CGRect(x: 100, y: 0, width: 800, height: 600),
                                  alpha: 1, layer: 0)
        let safari = Stack.Window(pid: 43, bounds: screen, alpha: 1, layer: 0)
        suite.expect(Stack.owner(at: point, in: [dockOverlay, finder, safari], ownPID: own) == 42,
                     "the window stack names the frontmost app window, through the Dock's overlay")

        let ownPanel = Stack.Window(pid: own, bounds: CGRect(x: 400, y: 0, width: 300, height: 40),
                                    alpha: 1, layer: 25)
        suite.expect(Stack.owner(at: point, in: [ownPanel, finder], ownPID: own) == nil,
                     "one of our own windows on top, at any layer, is never asked about")

        let clear = Stack.Window(pid: 44, bounds: screen, alpha: 0, layer: 0)
        let ownBehind = Stack.Window(pid: own, bounds: screen, alpha: 1, layer: 0)
        suite.expect(Stack.owner(at: point, in: [clear, finder, ownBehind], ownPID: own) == 42
                        && Stack.owner(at: CGPoint(x: 50, y: 20), in: [finder], ownPID: own) == nil
                        && Stack.owner(at: CGPoint(x: 50, y: 20), in: [finder, ownBehind], ownPID: own) == nil,
                     "transparent windows and windows elsewhere do not count")
    }

    private static func sourceCode(_ path: String) -> String {
        let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func wiring(_ suite: TestSuite) {
        let key = ForkDefaultsKey.gesturesEnabled
        suite.expect(ForkDefaults.registered[key] as? Bool == false,
                     "title bar trackpad gestures stay off by default")
        suite.expect(ForkDefaults.backupKeys.contains(key),
                     "the title bar gestures switch travels with the settings backup")
        let feature = sourceCode("Sources/Vorssaint/Fork/Core/ForkFeature.swift")
        suite.expect(feature.contains("case .trackpadGestures: return ForkDefaultsKey.gesturesEnabled")
                        && feature.contains("case .trackpadGestures: ForkGestures.sync()"),
                     "the gestures have their own switch on the Extras page, which starts or stops them")

        let page = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadSettings.swift")
        let hero = page.components(separatedBy: "private struct ForkTrackpadHero").dropFirst().first ?? ""
        suite.expect(page.contains("@AppStorage(ForkDefaultsKey.gesturesEnabled)")
                        && page.contains("gesturesEnabled.toggle()\n                ForkGestures.sync()")
                        && hero.contains("Text(text.enable)") && hero.contains("Text(text.caption)"),
                     "the gestures' own card switches them, under their title and caption")
        let extras = sourceCode("Sources/Vorssaint/Fork/Core/ForkExtrasSettings.swift")
        let toggle = extras.components(separatedBy: "private struct ForkFeatureToggle").dropFirst().first ?? ""
        suite.expect(extras.contains("ForEach(ForkFeature.allCases) { feature in")
                        && extras.contains("ForkTrackpadSettingsSections(text: FeatureStrings.forkTrackpadGestures(l10n.language)")
                        && toggle.contains("_isOn = AppStorage(wrappedValue: false, feature.enabledKey)")
                        && toggle.contains(".onChange(of: isOn) { _, _ in feature.sync() }"),
                     "the Extras page lists every fork feature with its switch, and the gestures' settings")

        let gestures = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkGestures.swift")
        let sync = gestures.components(separatedBy: "static func sync()").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        let suspend = gestures.components(separatedBy: "static func suspend()").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(sync.contains("SessionActivitySupport.tapShouldRun(featureWanted: wanted,")
                        && sync.contains("accessibilityGranted: AXIsProcessTrusted()")
                        && sync.contains("WindowLayoutIgnoredApps.shared.contains(bundleID: frontmost?.bundleIdentifier")
                        && sync.contains("if canRun && allowed {\n            ForkTrackpadGestureService.shared.start()")
                        && sync.contains("ForkTrackpadGestureService.shared.stop()")
                        && sync.contains("if !wanted { ForkTrackpadWindowPlacer.shared.reset() }")
                        && suspend.contains("ForkTrackpadGestureService.shared.stop()"),
                     "the gesture tap follows the switch, Accessibility, the session, ignored apps and suspension")
        let layout = sourceCode("Sources/Vorssaint/Services/WindowLayout/WindowLayoutService.swift")
        suite.expect(layout.contains("    func syncWithPreferences() {\n        defer { ForkBootstrap.windowLayoutDidSync() } // FORK(window-layout)\n")
                        && layout.contains("    func suspend() {\n        ForkBootstrap.windowLayoutWillSuspend() // FORK(window-layout)\n"),
                     "every official Window Layout sync and suspension reaches the gestures (seam window-layout)")
        let bootstrap = sourceCode("Sources/Vorssaint/Fork/Core/ForkBootstrap.swift")
        suite.expect(bootstrap.contains("DispatchQueue.main.async {\n            ForkGestures.sync()")
                        && bootstrap.contains("ForkDefaults.register()")
                        && bootstrap.contains("Permissions.shared.$accessibility")
                        && bootstrap.contains(".sink { _ in ForkGestures.sync() }")
                        && sourceCode("Sources/Vorssaint/Fork/Core/ForkBootstrap.swift")
                            .components(separatedBy: "static func windowLayoutDidSync()").dropFirst().first?
                            .contains("ForkGestures.sync()") == true,
                     "the gestures start at launch and follow Accessibility on their own")

        let tap = sourceCode("Sources/Vorssaint/Fork/Gestures/ForkTrackpadGestureService.swift")
        let observe = tap.components(separatedBy: "private func observe(").dropFirst().first ?? ""
        let observeBody = observe.components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(tap.contains("options: .listenOnly")
                        && tap.contains("PointerTapRunLoop.add(source)")
                        && !observeBody.isEmpty
                        && !observeBody.contains("AXUIElement")
                        && !observeBody.contains("machine.")
                        && observeBody.contains("DispatchQueue.main.async"),
                     "the tap only listens and hands events to the main thread without asking Accessibility")

        let commit = tap.components(separatedBy: "case .commit(let rawAction):").dropFirst().first ?? ""
        let commitBody = commit.components(separatedBy: "case .haptic").first ?? ""
        let quit = tap.components(separatedBy: "func quitDockApp(").dropFirst().first ?? ""
        let quitBody = quit.components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(commitBody.contains("(.dockApp(let pid)?, .quitApp)")
                        && commitBody.contains("Self.quitDockApp(pid: pid)")
                        && commitBody.contains("where action.isWindowAction:")
                        && quitBody.contains("app.terminate()")
                        && !quitBody.contains("forceTerminate")
                        && quitBody.contains("ProcessInfo.processInfo.processIdentifier")
                        && quitBody.contains("ForkTrackpadDock.protectedBundleIdentifiers"),
                     "a pinch on a Dock icon quits that app politely, never this app nor a protected one")
        suite.expect(commit.contains("ForkTrackpadModifierRemap.action(for: rawAction, modifierHeld: modifierHeld,")
                        && tap.contains("heldKeys: ForkTrackpadModifierKeys(flags: event.flags)")
                        && tap.contains("modifierHeld = input.heldKeys == strongerKeys")
                        && tap.contains("gridModifierHeld = input.heldKeys == gridKeys")
                        && tap.contains("(gridKeys, strongerKeys) = ForkTrackpadModifierKeys.current()")
                        && tap.contains("ForkTrackpadModifierRemap.action(for: action, modifierHeld: modifierHeld,"),
                     "a held modifier remaps both the commit and the live preview, read fresh from every event")
        let hit = tap.components(
            separatedBy: "let output = machine.handle(input.event, at: now, gridModifierHeld: gridModifierHeld)"
        ).dropFirst().first ?? ""
        let dockFirst = hit.range(of: "let dockHit = Self.dockItem(at: input.location)")
        let titlebarNext = hit.range(of: "Self.titlebarWindow(at: input.location")
        suite.expect(dockFirst != nil && titlebarNext != nil && dockFirst!.lowerBound < titlebarNext!.lowerBound
                        && tap.contains("DockClickSupport.dockStripContains(")
                        && tap.contains("DockClickSupport.dockOwnsPoint(")
                        && tap.contains("ForkTrackpadDock.itemIndex("),
                     "the Dock is asked about first, only inside its strip and while it is on screen")
        suite.expect(tap.contains("case .showPreview(let preview):")
                        && tap.contains("ForkTrackpadGesturePreview.shared.show(")
                        && tap.contains("case .hidePreview:\n                ForkTrackpadGesturePreview.shared.hide()"),
                     "the gesture's preview follows what the machine announces")
    }

    private static func strings(_ suite: TestSuite) {
        let all = AppLanguage.allCases.map(FeatureStrings.forkTrackpadGestures)
        suite.expect(all.count == 15
                        && all.allSatisfy { !$0.enable.isEmpty && !$0.caption.isEmpty },
                     "title bar gesture strings exist in every language")
        suite.expect(Set(all.map(\.caption)).count >= 14,
                     "title bar gesture captions are translated, not copied from English")
    }
}
