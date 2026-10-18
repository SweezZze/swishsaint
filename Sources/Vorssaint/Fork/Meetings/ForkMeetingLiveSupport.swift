// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The two sounds a meeting records, as the pill draws them: between 0
/// (silence) and 1 (loud). The engine keeps them under its lock and the
/// pill reads them about fifteen times a second.
struct ForkMeetingLevels: Equatable {
    var microphone: Float = 0
    var meeting: Float = 0

    static let silent = ForkMeetingLevels()
}

/// What the live surfaces know of the recording beyond the machine's pill
/// state: facts the service learns from the stream, the microphone and the
/// settings, sent again whenever one of them changes.
struct ForkMeetingLiveContext: Equatable {
    /// The meeting's name, shown when the pointer rests on the pill; `nil`
    /// shows the default one.
    var title: String?
    /// What the picture follows now: the ⧉ button offers the other one.
    var target: ForkMeetingCaptureTarget = .window
    /// Whether the picture may switch between the window and the display.
    var canSwitchTarget = true
    /// The meeting records the microphone (off by choice, or not allowed).
    var recordsMicrophone = true
    /// The microphone sends nothing: the pill crosses it out.
    var microphoneSilent = false
    /// The filmed window is minimized: the picture holds its last frame.
    var pictureFrozen = false
    /// The display of the recorded window, where the pill and the bubble
    /// appear; `nil` takes the display being worked on.
    var displayID: UInt32?

    // MARK: Fixes F2

    /// The filmed window's app, by name: "Chrome window".
    var appName: String?
    /// A window was asked for and none could be filmed: the whole display is.
    var noWindowToFilm = false
    /// The announcement the start's card copies while the consent reminder
    /// is on; `nil` when it is off.
    var announcement: String?

    // MARK: Fixes G1

    /// What the meeting track holds: the pill crosses its meter out and
    /// says why when it is silent.
    var trackSound: ForkMeetingTrackSound = .heard
}

/// What the pill shows, decided from the machine's state and the live
/// facts. Kept apart from the view so each rule is tested.
struct ForkMeetingPillLook: Equatable {
    enum Mark: Equatable {
        /// The red dot; it breathes unless motion is reduced.
        case recording(pulses: Bool)
        /// The orange pause bars, still.
        case paused
        /// A gauge: indeterminate without a progress.
        case working
    }

    /// The words or the meters between the time and the buttons.
    enum Status: Equatable {
        case meters
        case paused
        case diskLow(minutesLeft: Int)
        case pictureFrozen
        case stopping
        case finalizing(progress: Double?)
    }

    let mark: Mark
    let status: Status
    /// The time is shown, in orange when paused or short of disk.
    let showsClock: Bool
    let clockIsAlert: Bool
    /// Pause or resume, and stop: none once the recording stops.
    let showsControls: Bool
    let paused: Bool

    /// `nil` when the pill is hidden.
    init?(state: ForkMeetingPillState, context: ForkMeetingLiveContext, finalizingProgress: Double?,
          reducesMotion: Bool) {
        switch state {
        case .hidden:
            return nil
        case let .recording(_, diskMinutesLeft):
            mark = .recording(pulses: !reducesMotion)
            // The disk outranks the frozen picture: it ends the meeting.
            if let diskMinutesLeft { status = .diskLow(minutesLeft: diskMinutesLeft) }
            else if context.pictureFrozen { status = .pictureFrozen }
            else { status = .meters }
            showsClock = true
            clockIsAlert = diskMinutesLeft != nil
            showsControls = true
            paused = false
        case let .paused(_, _, diskMinutesLeft):
            mark = .paused
            status = diskMinutesLeft.map { .diskLow(minutesLeft: $0) } ?? .paused
            showsClock = true
            clockIsAlert = true
            showsControls = true
            paused = true
        case .stopping:
            mark = .working
            status = .stopping
            showsClock = false
            clockIsAlert = false
            showsControls = false
            paused = false
        case .finalizing:
            mark = .working
            status = .finalizing(progress: finalizingProgress.map { min(1, max(0, $0)) })
            showsClock = false
            clockIsAlert = false
            showsControls = false
            paused = false
        }
    }
}

/// The pill's numbers: its time, its size and where it sits.
enum ForkMeetingPillLayout {
    /// At rest, with minutes under the hour.
    static let restingSize = CGSize(width: 168, height: 32)
    /// Room between the pill and the island or the camera.
    static let gap: CGFloat = 8
    /// Room under the menu bar, as the recorder's own pill keeps.
    static let drop: CGFloat = 10
    /// Room the pill keeps from a display's edges.
    static let margin: CGFloat = 4
    /// Half the official recorder's own pill, centred under the menu bar
    /// (`RecorderIndicator`, 150 pt wide): ours never covers it.
    static let officialPillHalfWidth: CGFloat = 75

    /// "m:ss" under the hour, "h:mm:ss" from it on: a three-hour meeting
    /// reads 3:00:05, never 180:05.
    static func clock(_ elapsed: TimeInterval) -> String {
        let seconds = elapsed.isFinite ? max(0, Int(elapsed)) : 0
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// The camera housing's right edge in screen points. AppKit gives the
    /// area right of it in the display's own space on some displays and in
    /// the global one on others: a value outside the display is read as
    /// relative to it.
    static func cameraRightEdge(auxiliaryMinX: CGFloat, screenFrame: CGRect) -> CGFloat {
        let global = auxiliaryMinX >= screenFrame.minX && auxiliaryMinX <= screenFrame.maxX
        return global ? auxiliaryMinX : screenFrame.minX + auxiliaryMinX
    }

    /// Under the menu bar, just right of the island at rest, of the camera,
    /// or of the official recorder's pill (centred, should it record at the
    /// same time), whichever reaches furthest.
    static func defaultOrigin(size: CGSize, visibleFrame: CGRect, cameraRightEdge: CGFloat?,
                              islandFrame: CGRect?) -> CGPoint {
        let edges = [cameraRightEdge, islandFrame?.maxX, visibleFrame.midX + officialPillHalfWidth].compactMap { $0 }
        let left = (edges.max() ?? visibleFrame.midX) + gap
        let frame = CGRect(origin: CGPoint(x: left, y: visibleFrame.maxY - drop - size.height), size: size)
        return clamped(frame, into: visibleFrame).origin.wholePoints
    }

    /// Wholly inside the display's usable area, a margin from its edges.
    static func clamped(_ frame: CGRect, into visibleFrame: CGRect) -> CGRect {
        let area = visibleFrame.insetBy(dx: margin, dy: margin)
        guard area.width > 0, area.height > 0 else { return frame }
        var frame = frame
        frame.origin.x = min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width))
        frame.origin.y = min(max(frame.minY, area.minY), max(area.minY, area.maxY - frame.height))
        return frame
    }

    /// A new width for the pill: its left edge and its top stay, unless
    /// the wider pill would leave the display, which moves it left.
    static func resized(_ frame: CGRect, to size: CGSize, within visibleFrame: CGRect) -> CGRect {
        let top = frame.maxY
        let grown = CGRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height)
        let fitted = clamped(grown, into: visibleFrame)
        return CGRect(origin: fitted.origin.wholePoints, size: size)
    }
}

/// Where the pill was dragged, per display, as `fork.meetings.pillPositions`
/// keeps it: the gap between the display's top left corner and the pill's,
/// so a pill left beside the camera stays there whatever its width.
struct ForkMeetingPillPositions: Equatable {
    private(set) var offsets: [String: CGPoint] = [:]

    init() {}

    /// Anything unreadable starts afresh: a lost position only puts the pill
    /// back at its default place.
    init(json: String?) {
        guard let data = json?.data(using: .utf8),
              let stored = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return }
        for (display, pair) in stored where pair.count == 2 && pair.allSatisfy(\.isFinite) {
            offsets[display] = CGPoint(x: pair[0], y: pair[1])
        }
    }

    var json: String {
        let stored = offsets.mapValues { [Double($0.x), Double($0.y)] }
        guard let data = try? JSONEncoder().encode(stored) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The pill's origin on that display, back inside it if the display
    /// shrank since.
    func origin(on display: String, size: CGSize, screenFrame: CGRect, visibleFrame: CGRect) -> CGPoint? {
        guard let offset = offsets[display] else { return nil }
        let frame = CGRect(x: screenFrame.minX + offset.x, y: screenFrame.maxY - offset.y - size.height,
                           width: size.width, height: size.height)
        return ForkMeetingPillLayout.clamped(frame, into: visibleFrame).origin.wholePoints
    }

    mutating func remember(_ frame: CGRect, on display: String, screenFrame: CGRect) {
        offsets[display] = CGPoint(x: (frame.minX - screenFrame.minX).rounded(),
                                   y: (screenFrame.maxY - frame.maxY).rounded())
    }

    mutating func forget(_ display: String) {
        offsets[display] = nil
    }
}

/// Texts the live surfaces put together from numbers.
enum ForkMeetingLiveText {
    /// "52 min · 410 MB": how long the meeting is and how much room it takes,
    /// under the saved notice. A meeting under a minute reads one minute.
    static func savedDetail(seconds: TimeInterval, bytes: Int64?, language: AppLanguage) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = language.formattingLocale()
        formatter.calendar = calendar
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .short
        let rounded = (max(60, seconds.isFinite ? seconds : 0) / 60).rounded() * 60
        let length = formatter.string(from: rounded) ?? ""
        guard let bytes, bytes > 0 else { return length }
        return length + " · " + size(bytes, language: language)
    }

    /// "410 MB", "410 Mo", "410 МБ": in the app's language, like the length
    /// beside it, never in the system's. `ByteCountFormatter` has no locale.
    static func size(_ bytes: Int64, language: AppLanguage) -> String {
        bytes.formatted(.byteCount(style: .file).locale(language.formattingLocale()))
    }

    /// Two sentences said one after the other by VoiceOver: a full stop and
    /// a space, or the ideographic full stop alone after Chinese or Japanese
    /// (an ASCII "." there reads as a stray dot). Nothing is added after a
    /// text that already ends its sentence.
    static func sentences(_ first: String, _ second: String) -> String {
        guard let last = first.unicodeScalars.last else { return second }
        let ideographic = isIdeographic(last)
        if ".。!?！？".unicodeScalars.contains(last) { return first + (ideographic ? "" : " ") + second }
        return first + (ideographic ? "。" : ". ") + second
    }

    /// Han, kana and the CJK punctuation: Korean, written with spaces and
    /// full stops, is not.
    private static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF01...0xFF60: return true
        default: return false
        }
    }
}

private extension CGPoint {
    var wholePoints: CGPoint { CGPoint(x: x.rounded(), y: y.rounded()) }
}
