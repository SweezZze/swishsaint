// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import AVFoundation

/// The detection's parts, held by the service while the feature runs.
struct ForkMeetingDetection {
    var running = false
    /// One more at each start: a reading of a run stopped since is dropped.
    var generation = 0
    var resolver = ForkMeetingResolver()
    var windows: ForkMeetingWindowScanner?
    var microphones: ForkMeetingMicWatcher?
    var calendar: ForkMeetingCalendar?
    /// Ticks once a second while an offer, a countdown or "Cancel" waits.
    var clock: Timer?
    /// The last microphone reading, for the meeting app's input.
    var lastMicrophones: [ForkMeetingMicSignal] = []
    /// The meetings volume's free space, for the offers' requests: read off
    /// the main thread, trusted 15 s.
    var freeBytes: Int64?
    var freeBytesReadAt: Date?
    /// When the reading under way was asked, and its number: one given up
    /// after 15 s answers into nothing.
    var freeBytesAskedAt: Date?
    var freeBytesReading = 0
    /// The meetings whose app has used a microphone for a second, from the
    /// last resolution: "Always" starts only those.
    var onMicrophone: Set<ForkMeetingIdentity> = []
}

/// A meeting found on its own: the windows' titles and the microphones are
/// read, the resolver says which meetings are on, the machine offers them,
/// starts them ("Always") and stops them at their end.
///
/// ```
/// window scanner (3 s) ─┐
/// microphone watcher ───┼─► resolver.resolve ─► endProbable (each end) ─► candidates ─► tick
/// calendar (60 s) ──────┘                                    clock (1 s, offer, countdown, Cancel) ─► tick
/// ```
/// Its effects run here: the offer and the countdown through the
/// presenter, a meeting set aside in the resolver, a choice per provider in
/// `fork.meetings.apps`, a cancelled recording's folder to the Trash.
///
/// Nothing runs while the feature is off or its first-use sheet not
/// confirmed; turned off, every reader, listener and timer stops.
extension ForkMeetingService {
    // MARK: - Running

    /// From `sync()`, and when a permission it depends on changes.
    func syncDetection() {
        let wanted = ForkMeetingDetectionSupport.runs(wanted: isWanted, consentAcknowledged: consentAcknowledged,
                                                     terminating: terminating)
        if wanted, !detection.running {
            startDetection()
        } else if !wanted, detection.running {
            stopDetection()
        }
        if detection.running { syncCalendar() }
        syncDetectionClock()
    }

    private func startDetection() {
        detection.running = true
        detection.generation += 1
        let generation = detection.generation
        detection.resolver = ForkMeetingResolver(policies: ForkMeetingPolicies.load(defaults))
        let windows = ForkMeetingWindowScanner { [weak self] signals, unreadable in
            self?.take(ForkMeetingReading(at: Date(), windows: signals, titlesUnreadable: unreadable),
                       generation: generation)
        }
        detection.windows = windows
        windows.start()
        if ForkMeetingMicWatcher.isSupported {
            let microphones = ForkMeetingMicWatcher { [weak self] signals in
                self?.take(ForkMeetingReading(at: Date(), microphones: signals), generation: generation)
            }
            detection.microphones = microphones
            microphones.start()
        }
        refreshFreeSpace()
        log.notice("detection on, microphone signal \(ForkMeetingMicWatcher.isSupported ? "on" : "off", privacy: .public)")
    }

    private func stopDetection() {
        detection.running = false
        detection.generation += 1
        detection.windows?.stop()
        detection.microphones?.stop()
        detection.calendar?.stop()
        if let windows = detection.windows {
            let cost = windows.measuredCost
            let mean = Int((cost.meanMilliseconds * 1000).rounded())
            log.notice("detection off: \(cost.readings) window readings, \(mean) µs each")
        }
        detection.windows = nil
        detection.microphones = nil
        detection.calendar = nil
        detection.resolver.reset()
        detection.lastMicrophones = []
        detection.freeBytes = nil
        detection.freeBytesReadAt = nil
        detection.freeBytesAskedAt = nil
        detection.onMicrophone = []
        if detectedMeeting != nil { detectedMeeting = nil }
        // An offer goes with the feature; a recording is stopped by `sync()`.
        if case .offering = machine.phase { send(.featureDisabled) }
        // The machine forgets the meeting it saw: a start by hand names none.
        send(.candidates([], detectionRequest()))
    }

    /// "Name with the calendar": read while it is on and the calendar may
    /// be read; turned off, the names it gave go.
    private func syncCalendar() {
        let wanted = ForkMeetingCalendar.isOn(defaults)
        if wanted, detection.calendar == nil {
            let generation = detection.generation
            let calendar = ForkMeetingCalendar { [weak self] hints in
                self?.take(ForkMeetingReading(at: Date(), calendar: hints), generation: generation)
            }
            detection.calendar = calendar
            calendar.start()
        } else if !wanted, let calendar = detection.calendar {
            calendar.stop()
            detection.calendar = nil
            take(ForkMeetingReading(at: Date(), calendar: []), generation: detection.generation)
        }
    }

    // MARK: - Readings

    /// One reading through the resolver, then the machine: each end first,
    /// then the meetings on, then the time.
    private func take(_ read: ForkMeetingReading, generation: Int) {
        guard detection.running, generation == detection.generation, !terminating else { return }
        var reading = read
        if let microphones = reading.microphones {
            let owned = attributed(microphones)
            reading.microphones = owned
            detection.lastMicrophones = owned
        }
        // The page may have changed a provider's choice since, or the
        // countdown, during which an app's meeting back is the same one.
        let countdown = ForkMeetingAutoStop.load(defaults).countdown
        detection.resolver.policies = ForkMeetingPolicies.load(defaults)
        detection.resolver.endCountdown = countdown
        let resolution = detection.resolver.resolve(reading)
        detection.onMicrophone = resolution.onMicrophone
        for identity in resolution.ended {
            log.notice("meeting probably over: \(identity.value, privacy: .private)")
            send(.endProbable(identity, countdown: countdown))
        }
        let first = resolution.candidates.first
        if detectedMeeting != first { detectedMeeting = first }
        send(.candidates(resolution.candidates, detectionRequest()))
        send(.tick)
        refreshFreeSpace()
    }

    /// FaceTime's calls run in system processes no app owns: theirs are
    /// FaceTime's while it is open, nobody's otherwise. The running apps are
    /// asked only when such a process records.
    private func attributed(_ microphones: [ForkMeetingMicSignal]) -> [ForkMeetingMicSignal] {
        let table = ForkMeetingProviderTable.current
        let system = table.systemProcessBundles
        guard microphones.contains(where: { $0.appBundle == nil && $0.processBundle.map(system.contains) == true })
        else { return microphones }
        let hosts = table.systemProcessHosts
        var running: [String: Int32] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier, hosts.contains(bundle), running[bundle] == nil else { continue }
            running[bundle] = app.processIdentifier
        }
        return table.attributing(microphones, running: running)
    }

    /// What a start would be asked with now, for an offer and for "Always":
    /// like a start by hand, with the free space last read off the main
    /// thread (none once it is 15 s old: the offer greys rather than trust
    /// it), the microphone as it is allowed (never asked: nothing may pop up
    /// on its own), and the meetings whose app uses the microphone.
    func detectionRequest() -> ForkMeetingStartRequest {
        let free = ForkMeetingDetectionSupport.freeSpace(detection.freeBytes, readAt: detection.freeBytesReadAt,
                                                         now: Date())
        var facts = ForkMeetingStartFacts(freeBytes: free,
                                          screenRecordingAllowed: CGPreflightScreenCaptureAccess(),
                                          microphoneAllowed: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                                          officialRecorderBusy: officialRecorderBusy())
        facts.meetingsOnMicrophone = detection.onMicrophone
        return ForkMeetingStartRequest(settings: captureSettings(), facts: facts, title: nil)
    }

    /// Reads the free space again 10 s after the last reading, off the main
    /// thread: a volume may be slow, or gone. One that hangs for 15 s is
    /// given up and asked again; its late answer counts for nothing.
    private func refreshFreeSpace() {
        let now = Date()
        guard detection.running,
              ForkMeetingDetectionSupport.freeSpaceNeedsReading(readAt: detection.freeBytesReadAt,
                                                                askedAt: detection.freeBytesAskedAt, now: now) else { return }
        detection.freeBytesAskedAt = now
        detection.freeBytesReading += 1
        let reading = detection.freeBytesReading
        let generation = detection.generation
        let root = store.root()
        let freeBytes = self.freeBytes
        DispatchQueue.global(qos: .utility).async {
            let free = freeBytes(root)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.detection.running, generation == self.detection.generation,
                      reading == self.detection.freeBytesReading else { return }
                self.detection.freeBytesAskedAt = nil
                self.detection.freeBytes = free
                self.detection.freeBytesReadAt = Date()
            }
        }
    }

    /// The input the meeting's app records from (a capture device's unique
    /// ID), for "Meeting microphone (auto)", for the recording and for what
    /// the offer says it records; `nil` gives the system's.
    func meetingMicrophone(for meeting: ForkMeetingCandidate?) -> String? {
        ForkMeetingDetectionSupport.meetingInput(for: meeting, in: detection.lastMicrophones)
    }

    // MARK: - Clock

    /// After every run of the machine: the clock ticks only while time
    /// decides something.
    func syncDetectionClock() {
        let wanted = detection.running && ForkMeetingDetectionSupport.clockRuns(phase: machine.phase)
        if wanted, detection.clock == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.send(.tick) }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            detection.clock = timer
        } else if !wanted, let timer = detection.clock {
            timer.invalidate()
            detection.clock = nil
        }
    }

    // MARK: - The person's answers

    /// "Record" in the offer.
    func acceptOffer() {
        answerOffer(always: false)
    }

    /// "Record Sound Only" (or "Record with Picture") in the offer's menu:
    /// this one meeting otherwise than the setting, which stays as it is.
    func acceptOffer(target: ForkMeetingCaptureTarget) {
        answerOffer(always: false, target: target)
    }

    /// "Always for Meet": it records now, and on its own from then on.
    func alwaysForOffer() {
        answerOffer(always: true)
    }

    /// "Not now" (`.thisTime`), or "Never for Meet" (`.never`).
    func dismissOffer(_ scope: ForkMeetingDismissal) {
        guard case .offering = machine.phase else { return }
        // A start being prepared from this offer is given up.
        if preparingStart {
            preparingStart = false
            startAttempt.cancel()
        }
        send(.dismiss(scope))
    }

    /// "Cancel" within 5 s of a start "Always" made: the file is thrown away.
    func cancelAutoStart() {
        send(.cancelAutoStart)
    }

    /// The pill's stop. While "Cancel" runs after a start "Always" made, it
    /// cancels as "Cancel" does (the file goes to the Trash), and says so to
    /// VoiceOver: a stop then would keep a meeting nobody chose to record.
    func stopFromPill() {
        if ForkMeetingOfferTiming.pillStopCancels(undoUntil: machine.activeSession?.undoUntil, now: Date()) {
            cancelAutoStart()
        } else {
            stop()
        }
    }

    /// "Continue" during "Meeting over? Stopping in 15 s".
    func continueRecording() {
        send(.continueRecording)
    }

    /// "Copy the announcement" in the offer's menu: the person's text, or the
    /// default one in their language, for the meeting's chat.
    func copyAnnouncement() {
        let text = ForkMeetingStrings.current
        let announcement = ForkMeetingAnnouncementText.text(
            stored: defaults.string(forKey: ForkDefaultsKey.meetingsAnnouncement) ?? "", strings: text)
        presenter.copy(announcement)
    }

    /// "Record" and "Always" gather what the machine needs like a start by
    /// hand: the microphone asked if it never was (the person just chose to
    /// record), the free space read off the main thread. The offer may be
    /// gone by then: nothing starts.
    private func answerOffer(always: Bool, target: ForkMeetingCaptureTarget? = nil) {
        guard case let .offering(offer) = machine.phase, isWanted, !terminating, !preparingStart else { return }
        guard consentAcknowledged else { return presentConsent() }
        prepareSurfaces()
        presenter.resetAnnouncements()
        clearRefusal()
        let identity = offer.candidate.identity
        let attempt = startAttempt.begin()
        preparingStart = true
        refreshState()
        var settings = captureSettings()
        if let target { settings.target = target }
        let root = store.root()
        let freeBytes = self.freeBytes
        Self.microphoneAnswer(asking: settings.microphone != ForkMeetingCaptureSettings.microphoneOff) { [weak self] allowed in
            DispatchQueue.global(qos: .userInitiated).async {
                let free = freeBytes(root)
                DispatchQueue.main.async {
                    guard let self, self.startAttempt.answers(attempt) else { return }
                    self.preparingStart = false
                    if self.detection.running {
                        self.detection.freeBytes = free
                        self.detection.freeBytesReadAt = Date()
                    }
                    guard self.isWanted, !self.terminating, case let .offering(current) = self.machine.phase,
                          current.candidate.identity == identity else { return self.refreshState() }
                    let facts = ForkMeetingStartFacts(freeBytes: free,
                                                      screenRecordingAllowed: CGPreflightScreenCaptureAccess(),
                                                      microphoneAllowed: allowed,
                                                      officialRecorderBusy: self.officialRecorderBusy())
                    let request = ForkMeetingStartRequest(settings: settings, facts: facts, title: nil)
                    self.send(always ? .always(request) : .accept(request))
                }
            }
        }
    }

    // MARK: - Effects

    /// The detection's effects, in the machine's order.
    func runDetection(_ effect: ForkMeetingMachine.Effect) {
        onDetectionEffect?(effect)
        switch effect {
        case .showOffer, .collapseOffer, .hideOffer, .showUndo, .hideUndo, .showEndingSoon, .hideEndingSoon:
            // The presenter draws them (`ForkMeetingPresenter+Offer`), its
            // buttons configured with the others: "Settings" in the offer's
            // menu goes through `onFailureAction(.openMeetingsPage)`.
            prepareSurfaces()
            presenter.apply(effect, context: context)
        case let .silence(identity):
            detection.resolver.silence(identity, at: Date())
        case let .setPolicy(policy, provider):
            var policies = ForkMeetingPolicies.load(defaults)
            policies.set(policy, for: provider)
            policies.save(defaults)
            detection.resolver.policies = policies
        case let .discard(folder, askedAgain):
            discardCancelled(folder, askedAgain: askedAgain)
        case .startCapture, .pauseCapture, .resumeCapture, .restartStream, .switchTarget, .stopCapture, .showPill,
             .notice, .announce, .notify, .writeSidecar, .beginFinalize:
            break
        }
    }

    /// "Cancel" after a start "Always" made: once its file is closed, the
    /// folder goes to the Trash (deleted if the volume has none), off the
    /// main thread, then the notice says what became of it, and that the
    /// provider is offered again when "Cancel" took back its "Always". While
    /// the app quits, waited for within the quit's bound (shared with the
    /// file's close): a volume that hangs never holds the quit, and the
    /// folder, marked `cancelled` at the click, goes at the next launch.
    /// It was never finalized nor added to the recent captures.
    private func discardCancelled(_ folder: URL, askedAgain: String?) {
        let discard = { [store, log] () -> ForkMeetingDiscardOutcome in
            store.release(folder)
            let manager = FileManager.default
            let outcome = ForkMeetingDiscardOutcome.discard(
                trash: { try manager.trashItem(at: folder, resultingItemURL: nil) },
                remove: { try manager.removeItem(at: folder) })
            if outcome == .kept { log.error("a cancelled meeting stays in its folder") }
            return outcome
        }
        if terminating {
            let done = ForkMeetingBoundedWait.run(timeout: quitDeadline.timeIntervalSinceNow) { finished in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = discard()
                    finished()
                }
            }
            if !done { log.notice("quit: a cancelled meeting's folder is left to the next launch") }
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = discard()
            DispatchQueue.main.async {
                guard let self, !self.terminating else { return }
                self.presenter.showDiscarded(outcome, askedAgain: askedAgain)
            }
        }
    }
}
