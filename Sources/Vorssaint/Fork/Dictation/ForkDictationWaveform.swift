// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import CoreGraphics
import Foundation

/// The shape of the listening wave, from the last microphone levels.
///
/// - square root: speech sits low on the scale, and without it the wave
///   stays flat unless one shouts;
/// - smoothed over three neighbours: no frame-to-frame jitter;
/// - tapered at both ends: the wave thins out instead of being cut by the
///   frame;
/// - a floor that breathes: a perfectly flat line during a silence looks
///   like a crash, a slow ripple says "listening, you are just quiet".
struct ForkDictationWaveform {
    static let points = 32

    private(set) var levels: [Float] = Array(repeating: 0, count: points)

    /// A level between 0 and 1 (`ForkDictationSupport.level(rms:)`).
    mutating func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level.isFinite ? min(1, max(0, level)) : 0)
    }

    /// The breathing floor at `index`, `time` seconds into the animation.
    /// With Reduce Motion the clock stays at 0 and the floor is still.
    static func floor(index: Int, at time: TimeInterval) -> CGFloat {
        CGFloat(0.055 + 0.035 * sin(time * 2.1 + Double(index) * 0.42))
    }

    /// One height per point, between 0 and 1.
    func samples(at time: TimeInterval) -> [CGFloat] {
        let boosted = levels.map { CGFloat($0).squareRoot() }
        var smoothed = boosted
        for index in 1..<(boosted.count - 1) {
            smoothed[index] = boosted[index - 1] * 0.25 + boosted[index] * 0.5 + boosted[index + 1] * 0.25
        }
        let last = Double(smoothed.count - 1)
        return smoothed.enumerated().map { index, value in
            let taper = CGFloat(sin(Double(index) / last * .pi).squareRoot())
            return min(1, max(value, Self.floor(index: index, at: time)) * taper)
        }
    }
}
