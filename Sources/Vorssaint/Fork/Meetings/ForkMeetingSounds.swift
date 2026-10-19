// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit

/// The quiet sounds of a recording's start and stop (`fork.meetings.sounds`,
/// off by default), dictation's own two at its volume.
///
/// Never in the recording, by three ways in:
/// - **The meeting's sound.** `NSSound` plays in this process, which every
///   capture leaves out: the screen stream (`excludesCurrentProcessAudio`),
///   the whole Mac's tap (built without this process) and an app's tap
///   (that app's processes only). A sound played through the system's
///   sound server, `AudioServicesPlaySystemSound`, would not be.
/// - **The microphone, through the speakers.** The start's sound plays with
///   the machine's `startCapture`, before the folder, the stream, the file
///   and the taps are made; the microphone opens after all of them. The
///   stop's plays once the engine has stopped, its microphone closed.
/// - **Pauses** make no sound: one would land in the track at the resume.
///
/// Main thread only.
final class ForkMeetingSounds {
    static let shared = ForkMeetingSounds()

    enum Sound: CaseIterable {
        case start
        case stop

        var name: String {
            switch self {
            case .start: return "Tink"
            case .stop: return "Pop"
            }
        }
    }

    private lazy var players: [Sound: NSSound] = Self.load()

    private init() {}

    func play(_ sound: Sound) {
        guard let player = players[sound] else { return }
        player.stop()
        player.play()
    }

    private static func load() -> [Sound: NSSound] {
        var players: [Sound: NSSound] = [:]
        for sound in Sound.allCases {
            guard let player = NSSound(named: NSSound.Name(sound.name))?.copy() as? NSSound else { continue }
            player.volume = ForkDictationService.soundVolume
            players[sound] = player
        }
        return players
    }
}
