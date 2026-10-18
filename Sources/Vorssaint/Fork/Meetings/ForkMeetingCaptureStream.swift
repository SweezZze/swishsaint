// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import CoreMedia
import ScreenCaptureKit

/// The meeting's screen stream: one window, or the display that holds it,
/// in an output of fixed size, with the pointer, 30 frames a second, and the
/// sound of every app but this one when asked.
///
/// - **A window** is filmed on its own (`desktopIndependentWindow`): it is
///   followed from one display or Space to another, and nothing that covers
///   it gets in. Centred in the output (`destinationRect`): left alone,
///   ScreenCaptureKit draws it in the top-left corner (spike S5).
/// - **A display** leaves out every window of this app, the ones opened
///   after the start included (`excludingApplications`): the pill, the
///   bubble and the island are never in a meeting's picture.
/// - **Switching** window ↔ display changes the filter of the running stream
///   (41–67 ms measured), without a new stream, so the writer sees nothing.
/// - **Restarting** (after a sleep, a display unplugged) builds a new stream
///   for the same callbacks; every timestamp is on the host clock, so the new
///   stream's frames follow the old ones in the same file.
/// - **A minimized or hidden window** sends one last frame marked
///   "suspended", then nothing at all, and no delegate call (spike S5): that
///   status, and the next real picture, are what `frozen` reports.
///
/// ScreenCaptureKit keeps its delegate and outputs weakly: a stream whose
/// receiver nobody else holds goes silent. So `Receiver` is owned here, strongly, for as long as its stream lives.
/// Every callback of a stream runs on `queue`; a callback from a stream that
/// was replaced or stopped is dropped there.
final class ForkMeetingCaptureStream: @unchecked Sendable {
    /// What to film, resolved when the stream starts or switches.
    enum Aim: Equatable {
        case window(CGWindowID)
        /// The display holding this window, or the main display.
        case displayOf(CGWindowID?)
    }

    struct Callbacks {
        /// Capture queue: a frame with a picture, on the host clock.
        var video: (CMSampleBuffer) -> Void
        /// Capture queue: the stream's sound, on the host clock.
        var audio: (CMSampleBuffer) -> Void
        /// Capture queue: the picture stopped (true) or came back (false).
        var frozen: (Bool) -> Void
        /// Capture queue: the running stream ended without being asked.
        var stopped: (ForkMeetingCaptureSupport.StreamStop) -> Void
    }

    let queue = DispatchQueue(label: "fork.meetings.capture", qos: .userInitiated)
    let outputSize: ForkMeetingPixelSize
    private let capturesAudio: Bool
    private let callbacks: Callbacks
    /// This app's windows the caller knows, for a display filter made while
    /// the app is not listed.
    private let excludedWindows: Set<CGWindowID>

    private let lock = NSLock()
    // Under `lock`.
    private var stream: SCStream?
    private var receiver: Receiver?
    private var generation = 0
    private var aim: Aim?
    /// The window or the display the running stream films, resolved.
    private var filmed: ForkMeetingFilmed?
    private var configuration: SCStreamConfiguration?
    /// The window's shape the picture was last centred for.
    private var placedAspect: Double?
    private var isFrozen = false
    private var stopping = false

    init(outputSize: ForkMeetingPixelSize, capturesAudio: Bool, excludedWindows: Set<CGWindowID> = [],
         callbacks: Callbacks) {
        self.outputSize = outputSize
        self.capturesAudio = capturesAudio
        self.excludedWindows = excludedWindows
        self.callbacks = callbacks
    }

    // MARK: - Resolving

    /// What `aim` points at, read from ScreenCaptureKit's list (windows on
    /// other Spaces included). `excluding`: windows of this app known to the
    /// caller, left out of a display when the app itself is not listed. Any
    /// thread; answers on an arbitrary one.
    static func resolve(_ aim: Aim, excluding: Set<CGWindowID> = [],
                        completion: @escaping (Result<Resolved, ForkMeetingCaptureSupport.StreamStop>) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            guard let content else {
                completion(.failure(error.map { Self.stop(for: $0) } ?? ForkMeetingCaptureSupport.StreamStop.failed))
                return
            }
            if let resolved = Resolved.make(aim, in: content, excluding: excluding) {
                completion(.success(resolved))
            } else {
                completion(.failure(.sourceGone))
            }
        }
    }

    /// What `aim` points at; a window that is gone gives way to the display
    /// that held it (`ForkMeetingCaptureSupport.unresolved`), with the aim
    /// really used. Answers on an arbitrary queue.
    static func resolveOrDisplay(_ aim: Aim, excluding: Set<CGWindowID> = [],
                                 completion: @escaping (Result<(Resolved, Aim), ForkMeetingCaptureSupport.StreamStop>) -> Void) {
        resolve(aim, excluding: excluding) { result in
            switch result {
            case let .success(resolved):
                completion(.success((resolved, aim)))
            case let .failure(stop):
                guard case let .window(id) = aim,
                      ForkMeetingCaptureSupport.unresolved(stop, aimsAtWindow: true) == .filmDisplay else {
                    return completion(.failure(stop))
                }
                let display = Aim.displayOf(id)
                resolve(display, excluding: excluding) { completion($0.map { ($0, display) }) }
            }
        }
    }

    /// A filter and what it shows.
    struct Resolved: @unchecked Sendable {
        let filter: SCContentFilter
        /// The window's shape, width over height, for a window.
        let windowAspect: Double?
        /// The display's size in pixels, for the output size.
        let displayPixels: ForkMeetingPixelSize
        let isWindow: Bool
        /// The window, or the display, this filter shows.
        let filmed: ForkMeetingFilmed
        /// The app of the window aimed at, when there is one: the app whose
        /// sound the meeting track hears.
        let ownerPID: pid_t?
        /// A display's filter leaves out every window of this app, those
        /// opened later included. False when the app was not listed: only
        /// the windows known then are left out, and the filter is made again
        /// once it is listed.
        var excludesOwnApp = true
        /// The windows of this app a display's filter leaves out one by one,
        /// when the app was not listed.
        var ownWindows: Set<CGWindowID> = []

        static func make(_ aim: Aim, in content: SCShareableContent, excluding: Set<CGWindowID> = []) -> Resolved? {
            let mainID = CGMainDisplayID()
            let frames = content.displays.map { ForkMeetingDisplayFrame(id: $0.displayID, frame: $0.frame) }
            func pixels(of display: SCDisplay) -> ForkMeetingPixelSize {
                let mode = CGDisplayCopyDisplayMode(display.displayID)
                let width = mode?.pixelWidth ?? display.width
                let height = mode?.pixelHeight ?? display.height
                return ForkMeetingPixelSize(width: max(2, width), height: max(2, height))
            }
            switch aim {
            case let .window(id):
                guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
                let displayID = ForkMeetingCaptureSupport.display(holding: window.frame, displays: frames, main: mainID)
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                        ?? content.displays.first else { return nil }
                let aspect = window.frame.height > 0 ? Double(window.frame.width / window.frame.height) : nil
                return Resolved(filter: SCContentFilter(desktopIndependentWindow: window), windowAspect: aspect,
                                displayPixels: pixels(of: display), isWindow: true, filmed: .window(id),
                                ownerPID: window.owningApplication?.processID)
            case let .displayOf(windowID):
                let window = windowID.flatMap { id in content.windows.first(where: { $0.windowID == id }) }
                let displayID = ForkMeetingCaptureSupport.display(holding: window?.frame, displays: frames, main: mainID)
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                        ?? content.displays.first else { return nil }
                // Every window of this app, present and future, stays out.
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let own = content.applications.filter { $0.processID == ownPID }
                let filter: SCContentFilter
                if own.isEmpty {
                    // Not listed: an empty exclusion would let the pill in.
                    // Its windows known now stay out, one by one.
                    let ours = content.windows.filter {
                        $0.owningApplication?.processID == ownPID || excluding.contains($0.windowID)
                    }
                    filter = SCContentFilter(display: display, excludingWindows: ours)
                } else {
                    filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                }
                let ownWindows = own.isEmpty
                    ? Set(content.windows.filter {
                        $0.owningApplication?.processID == ownPID || excluding.contains($0.windowID)
                    }.map(\.windowID))
                    : []
                return Resolved(filter: filter, windowAspect: nil, displayPixels: pixels(of: display), isWindow: false,
                                filmed: .display(display.displayID), ownerPID: window?.owningApplication?.processID,
                                excludesOwnApp: !own.isEmpty, ownWindows: ownWindows)
            }
        }
    }

    // MARK: - Lifecycle

    /// Starts a stream on `resolved`. `willStart` runs just before the stream
    /// is asked to start, with the host time, so the writer's zero comes
    /// first. Answers once, on an arbitrary queue: `nil` when it runs.
    func start(_ resolved: Resolved, aim: Aim, willStart: @escaping (Double) -> Void,
               completion: @escaping (ForkMeetingCaptureSupport.StreamStop?) -> Void) {
        let configuration = makeConfiguration(for: resolved)
        let receiver = Receiver(owner: self)
        let stream = SCStream(filter: resolved.filter, configuration: configuration, delegate: receiver)
        do {
            try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: queue)
            if capturesAudio { try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: queue) }
        } catch {
            completion(Self.stop(for: error))
            return
        }
        let accepted = lock.withLock { () -> Bool in
            guard !stopping else { return false }
            generation += 1
            receiver.generation = generation
            self.stream = stream
            self.receiver = receiver
            self.aim = aim
            filmed = resolved.filmed
            self.configuration = configuration
            placedAspect = resolved.windowAspect
            // `isFrozen` stays: the new stream's first frame says otherwise.
            return true
        }
        guard accepted else { return completion(.ignored) }
        willStart(ForkMeetingWriter.hostSeconds())
        stream.startCapture { [self] error in
            guard let error else {
                // `stop`, or another restart, came while it started: it let
                // go of a stream that was not running yet, so this one is
                // stopped here, never left running unowned.
                guard lock.withLock({ stopping || self.stream !== stream }) else {
                    if !resolved.isWindow, !resolved.excludesOwnApp {
                        refreshOwnExclusion(of: stream, tries: 0, leftOut: resolved.ownWindows)
                    }
                    return completion(nil)
                }
                stream.stopCapture { _ in withExtendedLifetime(receiver) {} }
                return completion(.ignored)
            }
            lock.withLock {
                if self.stream === stream { self.stream = nil; self.receiver = nil }
            }
            completion(Self.stop(for: error))
        }
    }

    /// Films `aim` instead, on the same stream: the output keeps its size.
    /// A window that is gone gives way to its display. Answers on an
    /// arbitrary queue with the aim filmed now, `nil` when the stream
    /// refused (the caller then builds a new one).
    func switchTo(_ aim: Aim, completion: @escaping (Aim?) -> Void) {
        guard let stream = lock.withLock({ stopping ? nil : self.stream }) else { return completion(nil) }
        Self.resolveOrDisplay(aim, excluding: excludedWindows) { [self] result in
            guard case let .success((resolved, used)) = result else { return completion(nil) }
            // Already what is filmed (⧉ to a window that went, on its
            // display): the display resolved, not the aim, which stays the
            // same when the window moved to another display.
            if lock.withLock({
                self.stream === stream
                    && ForkMeetingFilmed.switchChangesNothing(current: filmed, next: resolved.filmed)
            }) {
                lock.withLock { self.aim = used }
                return completion(used)
            }
            stream.updateContentFilter(resolved.filter) { [self] error in
                guard error == nil else { return completion(nil) }
                let configuration = lock.withLock { () -> SCStreamConfiguration? in
                    guard self.stream === stream, let configuration = self.configuration else { return nil }
                    self.aim = used
                    filmed = resolved.filmed
                    placedAspect = resolved.windowAspect
                    place(configuration, aspect: resolved.windowAspect)
                    return configuration
                }
                guard let configuration else { return completion(nil) }
                if !resolved.isWindow, !resolved.excludesOwnApp {
                    refreshOwnExclusion(of: stream, tries: 0, leftOut: resolved.ownWindows)
                }
                stream.updateConfiguration(configuration) { error in completion(error == nil ? used : nil) }
            }
        }
    }

    /// A new stream films `aim`, for the same callbacks, and the current one
    /// (if any) ends, only once the new aim resolved: a running stream is
    /// never cut for a target that cannot be filmed. A window that is gone
    /// gives way to its display; the displays coming back after a sleep are
    /// waited for. Answers once, on an arbitrary queue, with the aim filmed
    /// (`nil` stop: it runs).
    func restart(_ aim: Aim, completion: @escaping (ForkMeetingCaptureSupport.StreamStop?, Aim) -> Void) {
        RestartAttempt(owner: self, aim: aim, completion: completion).run()
    }

    /// Stops the running stream without giving up: `restart` builds the next
    /// one (a sleep). Frames still on their way are dropped.
    func suspend() {
        detach {}
    }

    /// Lets go of the running stream, which stops; `then` runs once it did.
    /// Its receiver is kept until then: the stream may still call it.
    private func detach(then: @escaping () -> Void) {
        let (old, receiver) = lock.withLock { () -> (SCStream?, Receiver?) in
            defer {
                stream = nil
                self.receiver = nil
                generation += 1
            }
            return (stream, self.receiver)
        }
        guard let old else { return then() }
        old.stopCapture { _ in
            withExtendedLifetime(receiver) { then() }
        }
    }

    /// A display filter made while this app was not listed: made again once
    /// it is (the pill shows up right after the start), so the windows it
    /// opens later stay out too. Until then, each look leaves out the
    /// windows of ours listed by then (`leftOut`, those already left out).
    /// It never gives up while the stream films that display
    /// (`ForkMeetingCaptureSupport.exclusionRetryDelay`); a new stream starts
    /// its own.
    private func refreshOwnExclusion(of stream: SCStream, tries: Int, leftOut: Set<CGWindowID>) {
        queue.asyncAfter(deadline: .now() + ForkMeetingCaptureSupport.exclusionRetryDelay(tries: tries)) { [self] in
            guard let aim = lock.withLock({ !stopping && self.stream === stream ? self.aim : nil }),
                  case .displayOf = aim else { return }
            Self.resolve(aim, excluding: excludedWindows) { [self] result in
                guard lock.withLock({ !stopping && self.stream === stream && self.aim == aim }) else { return }
                guard case let .success(resolved) = result, !resolved.isWindow else {
                    return refreshOwnExclusion(of: stream, tries: tries + 1, leftOut: leftOut)
                }
                if resolved.excludesOwnApp || resolved.ownWindows != leftOut {
                    stream.updateContentFilter(resolved.filter) { _ in }
                }
                guard !resolved.excludesOwnApp else { return }
                refreshOwnExclusion(of: stream, tries: tries + 1, leftOut: resolved.ownWindows)
            }
        }
    }

    /// Whether a stream runs (none after `suspend`, or once it died).
    var isRunning: Bool { lock.withLock { stream != nil } }

    /// Stops for good and drains the capture queue, so no frame is on its
    /// way once `completion` runs (on an arbitrary queue).
    func stop(completion: @escaping () -> Void) {
        lock.withLock { stopping = true }
        // Frames that passed their check before it are on the queue: once
        // it is drained, none is left.
        detach { [queue] in queue.async { completion() } }
    }

    var currentAim: Aim? { lock.withLock { aim } }

    var pictureIsFrozen: Bool { lock.withLock { isFrozen } }

    // MARK: - Configuration

    private func makeConfiguration(for resolved: Resolved) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(ForkMeetingQuality.Rates.frameRate))
        // 420v straight to the encoder: two points of CPU less than BGRA, and
        // nothing is composited here (spike S1).
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // Without it, sRGB colours come out shifted (spike S5).
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = true
        if capturesAudio {
            configuration.capturesAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            // The pill's sounds, and the mixer's re-render of every app.
            configuration.excludesCurrentProcessAudio = true
        }
        place(configuration, aspect: resolved.windowAspect)
        return configuration
    }

    /// A window centred in the output; a display left to fill it, which
    /// ScreenCaptureKit centres by itself. `backgroundColor` is left alone:
    /// it is not retained, and a temporary colour crashes (spike S5).
    private func place(_ configuration: SCStreamConfiguration, aspect: Double?) {
        if let aspect {
            configuration.destinationRect = ForkMeetingCaptureSupport.centeredRect(aspect: aspect, in: outputSize)
        } else {
            configuration.destinationRect = .zero
        }
    }

    // MARK: - Callbacks

    fileprivate func receive(_ sample: CMSampleBuffer, of type: SCStreamOutputType, from stream: SCStream,
                             generation: Int) {
        guard lock.withLock({ !stopping && self.generation == generation && self.stream === stream }),
              CMSampleBufferIsValid(sample),
              let clock = stream.synchronizationClock else { return }
        switch type {
        case .screen:
            let kind = Self.frameKind(of: sample)
            if kind == .idle { return }
            let frozen = kind == .frozen
            let changed = lock.withLock { () -> Bool in
                defer { isFrozen = frozen }
                return isFrozen != frozen
            }
            if changed { callbacks.frozen(frozen) }
            guard !frozen, CMSampleBufferGetImageBuffer(sample) != nil else { return }
            followWindowShape(of: sample, stream: stream)
            guard let synchronized = RecorderSampleTiming.converted(sample, from: clock,
                                                                    to: CMClockGetHostTimeClock()) else { return }
            callbacks.video(synchronized)
        case .audio:
            guard let synchronized = RecorderSampleTiming.converted(sample, from: clock,
                                                                    to: CMClockGetHostTimeClock()) else { return }
            callbacks.audio(synchronized)
        default:
            return
        }
    }

    fileprivate func stopped(_ stream: SCStream, error: Error, generation: Int) {
        let current = lock.withLock { () -> Bool in
            guard !stopping, self.generation == generation, self.stream === stream else { return false }
            self.stream = nil
            receiver = nil
            return true
        }
        guard current else { return }
        let stop = Self.stop(for: error)
        guard stop != .ignored else { return }
        queue.async { [callbacks] in callbacks.stopped(stop) }
    }

    /// A window resized to another shape is centred again: each frame says
    /// where its content sits, whatever the units, so its shape is known.
    private func followWindowShape(of sample: CMSampleBuffer, stream: SCStream) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.contentRect] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), rect.height > 0 else { return }
        let observed = Double(rect.width / rect.height)
        let configuration = lock.withLock { () -> SCStreamConfiguration? in
            guard case .window = aim, self.stream === stream, let configuration = self.configuration,
                  ForkMeetingCaptureSupport.needsRecentering(applied: placedAspect, observed: observed)
            else { return nil }
            placedAspect = observed
            place(configuration, aspect: observed)
            return configuration
        }
        guard let configuration else { return }
        stream.updateConfiguration(configuration) { _ in }
    }

    private static func frameKind(of sample: CMSampleBuffer) -> ForkMeetingCaptureSupport.FrameKind {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return .idle }
        return ForkMeetingCaptureSupport.frameKind(status: raw)
    }

    static func stop(for error: Error) -> ForkMeetingCaptureSupport.StreamStop {
        let error = error as NSError
        return ForkMeetingCaptureSupport.streamStop(domain: error.domain, code: error.code)
    }

    // MARK: - Restart

    /// One rebuild, tried after each of `restartDelays` until a stream runs.
    /// Its own queue's work, one step after the other: never two at once.
    private final class RestartAttempt: @unchecked Sendable {
        private let owner: ForkMeetingCaptureStream
        private var aim: Aim
        private let completion: (ForkMeetingCaptureSupport.StreamStop?, Aim) -> Void
        private var tries = 0

        init(owner: ForkMeetingCaptureStream, aim: Aim,
             completion: @escaping (ForkMeetingCaptureSupport.StreamStop?, Aim) -> Void) {
            self.owner = owner
            self.aim = aim
            self.completion = completion
        }

        func run() {
            let delays = ForkMeetingCaptureSupport.restartDelays
            guard tries < delays.count else { return completion(.failed, aim) }
            let delay = delays[tries]
            tries += 1
            owner.queue.asyncAfter(deadline: .now() + delay) { [self] in attempt() }
        }

        private func attempt() {
            if owner.lock.withLock({ owner.stopping }) {
                completion(.ignored, aim)
                return
            }
            ForkMeetingCaptureStream.resolveOrDisplay(aim, excluding: owner.excludedWindows) { [self] result in
                switch result {
                case let .success((resolved, used)):
                    aim = used
                    // The old stream's error (-3808 when it already died)
                    // means nothing: it is let go before the new one starts.
                    owner.detach { [self] in
                        owner.start(resolved, aim: used, willStart: { _ in }) { [self] stop in
                            if let stop { retry(after: stop) } else { completion(nil, used) }
                        }
                    }
                case let .failure(stop):
                    retry(after: stop)
                }
            }
        }

        /// A refusal of the permission will not change by waiting; a window
        /// that went between the resolving and the start gives way to its
        /// display at once.
        private func retry(after stop: ForkMeetingCaptureSupport.StreamStop) {
            let window: CGWindowID? = { if case let .window(id) = aim { return id }; return nil }()
            switch ForkMeetingCaptureSupport.unresolved(stop, aimsAtWindow: window != nil) {
            case .giveUp:
                completion(stop, aim)
            case .filmDisplay:
                aim = .displayOf(window)
                owner.queue.async { [self] in attempt() }
            case .retry:
                run()
            }
        }
    }
}

/// The stream's delegate and output, kept alive by `ForkMeetingCaptureStream`
/// since ScreenCaptureKit holds them weakly.
private final class Receiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private weak var owner: ForkMeetingCaptureStream?
    /// Set once, before the stream starts.
    var generation = 0

    init(owner: ForkMeetingCaptureStream) {
        self.owner = owner
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        owner?.receive(sampleBuffer, of: type, from: stream, generation: generation)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        owner?.stopped(stream, error: error, generation: generation)
    }
}
