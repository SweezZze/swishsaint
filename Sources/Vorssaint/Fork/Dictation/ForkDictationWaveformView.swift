// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import SwiftUI

/// The voice as one full, symmetric wave rather than bars: each point is
/// smoothed on its neighbours (`ForkDictationWaveform`), so the shape glides
/// from one frame to the next instead of flickering.
///
/// Drawn in a `Canvas` fed by the bubble's own clock, never a
/// `TimelineView`: bran crashed in the isolation check of its content
/// closure, once per press of the dictation key.
struct ForkDictationWaveformView: View {
    /// Envelope values between 0 and 1, oldest first.
    let samples: [CGFloat]

    var body: some View {
        Canvas { context, size in
            Self.draw(samples, in: context, size: size)
        }
        .accessibilityHidden(true)
    }

    static func draw(_ samples: [CGFloat], in context: GraphicsContext, size: CGSize) {
        guard samples.count > 1 else { return }
        let step = size.width / CGFloat(samples.count - 1)
        let middle = size.height / 2
        let reach = max(0, size.height / 2 - 0.5)
        func point(_ index: Int, below: Bool) -> CGPoint {
            let amplitude = min(1, max(0, samples[index])) * reach
            return CGPoint(x: CGFloat(index) * step, y: below ? middle + amplitude : middle - amplitude)
        }

        // The top edge through the midpoints of quadratic curves: no corners,
        // without solving for a real spline. The bottom is its exact mirror,
        // walked backwards.
        var path = Path()
        path.move(to: point(0, below: false))
        for index in 1..<samples.count {
            let previous = point(index - 1, below: false)
            let current = point(index, below: false)
            path.addQuadCurve(to: CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2),
                              control: previous)
            if index == samples.count - 1 { path.addLine(to: current) }
        }
        for index in stride(from: samples.count - 1, through: 0, by: -1) {
            let current = point(index, below: true)
            guard index < samples.count - 1 else {
                path.addLine(to: current)
                continue
            }
            let next = point(index + 1, below: true)
            path.addQuadCurve(to: CGPoint(x: (next.x + current.x) / 2, y: (next.y + current.y) / 2),
                              control: next)
        }
        path.closeSubpath()

        // The past fades out, the present is sharp: the eye reads it left to
        // right without anything else having to move.
        context.fill(path, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.25), .white.opacity(0.6), .white.opacity(0.95)]),
            startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
    }
}
