// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

/// The trackpad gesture settings a person can tune, each a short ladder of
/// steps rather than a raw number: "more sensitive" means something, a
/// threshold of 7 does not.
///
/// A step is stored as its index. Each ladder reads from left to right the
/// way its slider does, and its default step is the value the gestures
/// used before they could be tuned.
enum ForkTrackpadTuning: CaseIterable {
    /// The share of the screen a double tap centers the window at.
    case centerSize
    /// How far two fingers travel before a swipe step counts: less travel
    /// is more sensitive, so the ladder runs from long to short.
    case swipeSensitivity
    /// The same for pinches, in magnification.
    case pinchSensitivity
    /// The stillness that validates a step, so another one can follow.
    case stepPause
    /// The stillness that gives the gesture up.
    case cancelDelay
    /// How far from the top of a window a hand-drawn title bar still counts.
    case titlebarBand
    /// How big the preview standing in for the pointer is, as a scale.
    case previewSize

    var key: String {
        switch self {
        case .centerSize: return ForkDefaultsKey.centerSizeStep
        case .swipeSensitivity: return ForkDefaultsKey.swipeSensitivityStep
        case .pinchSensitivity: return ForkDefaultsKey.pinchSensitivityStep
        case .stepPause: return ForkDefaultsKey.stepPauseStep
        case .cancelDelay: return ForkDefaultsKey.cancelDelayStep
        case .titlebarBand: return ForkDefaultsKey.titlebarBandStep
        case .previewSize: return ForkDefaultsKey.previewSizeStep
        }
    }

    /// The values, left to right on the slider.
    var steps: [Double] {
        switch self {
        case .centerSize: return [0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1]
        case .swipeSensitivity: return [40, 25, 16, 10, 7, 5, 3]
        case .pinchSensitivity: return [0.2, 0.12, 0.08, 0.05, 0.03, 0.02, 0.012]
        // Every pause stays under the shortest cancel delay: a pause as long
        // as the cancel would give the gesture up before any step counts.
        case .stepPause: return [0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5]
        case .cancelDelay: return [0.6, 0.8, 1, 1.2, 1.5, 2]
        case .titlebarBand: return [24, 32, 40, 52, 64, 80, 100]
        case .previewSize: return [0.6, 0.8, 1, 1.25, 1.5, 2, 2.5]
        }
    }

    var defaultStep: Int {
        switch self {
        case .centerSize: return 2
        case .swipeSensitivity: return 5
        case .pinchSensitivity: return 5
        case .stepPause: return 1
        case .cancelDelay: return 1
        case .titlebarBand: return 2
        case .previewSize: return 2
        }
    }

    var defaultValue: Double { steps[defaultStep] }

    /// A stored step, kept on the ladder: a value from a longer ladder of
    /// another version lands on its nearest end.
    func clampedStep(_ stored: Int) -> Int {
        min(max(stored, 0), steps.count - 1)
    }

    func value(atStep stored: Int) -> Double {
        steps[clampedStep(stored)]
    }

    /// The value in use now. A missing key reads as the default step.
    var current: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return value(atStep: defaults.integer(forKey: key))
    }

    /// The gesture machine's configuration with every tuned value in it.
    static func apply(to configuration: inout ForkTrackpadGestureMachine.Configuration,
                      value: (ForkTrackpadTuning) -> Double = { $0.current }) {
        configuration.swipeThreshold = value(.swipeSensitivity)
        configuration.pinchThreshold = value(.pinchSensitivity)
        configuration.stepPause = value(.stepPause)
        configuration.cancelTimeout = value(.cancelDelay)
    }
}
