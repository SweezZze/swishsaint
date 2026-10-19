// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AVFoundation
import Combine
import Foundation

/// The detail's player, shared by the video, the strip of marked moments
/// and the transcript that follows it: one `AVPlayer`, its time four times
/// a second while it plays, its speed. Main thread only.
final class ForkMeetingPlaybackController: ObservableObject {
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var duration: TimeInterval?
    @Published private(set) var speed: Float = 1
    @Published private(set) var isPlaying = false

    private(set) var player: AVPlayer?
    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?

    /// A new player on `url`, the old one let go. `nil`: none.
    func load(_ url: URL?) -> AVPlayer? {
        unload()
        guard let url else { return nil }
        let player = AVPlayer(url: url)
        player.defaultRate = speed
        self.player = player
        time = 0
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) {
            [weak self] now in
            guard let self, now.isNumeric else { return }
            let seconds = now.seconds
            if abs(seconds - self.time) >= 0.05 { self.time = seconds }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let playing = player.rate != 0
            DispatchQueue.main.async {
                guard let self, self.player === player, self.isPlaying != playing else { return }
                self.isPlaying = playing
            }
        }
        durationObservation = player.currentItem?.observe(\.duration, options: [.initial, .new]) { [weak self, weak player] item, _ in
            let length = item.duration
            guard length.isNumeric, length.seconds > 0 else { return }
            let seconds = length.seconds
            DispatchQueue.main.async {
                guard let self, let player, self.player === player, self.duration != seconds else { return }
                self.duration = seconds
            }
        }
        return player
    }

    func unload() {
        durationObservation = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObservation = nil
        player?.pause()
        player = nil
        duration = nil
        if isPlaying { isPlaying = false }
    }

    /// Plays from `seconds`, exactly: a click on a line or a marker.
    func play(from seconds: TimeInterval) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        time = max(0, seconds)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] done in
            guard done else { return }
            DispatchQueue.main.async { player?.play() }
        }
    }

    /// 1×, 1.5×, 2×: kept by the play button too (`defaultRate`).
    func setSpeed(_ speed: Float) {
        self.speed = speed
        player?.defaultRate = speed
        if let player, player.rate != 0 { player.rate = speed }
    }

    deinit {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        player?.pause()
    }
}
