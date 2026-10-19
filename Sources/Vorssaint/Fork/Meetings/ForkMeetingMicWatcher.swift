// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import CoreAudio

/// Which processes record from a microphone, read from CoreAudio's process
/// objects (`IsRunningInput`): a meeting app's microphone makes or keeps its
/// meeting alive, and its input is the one "Meeting microphone (auto)"
/// records.
///
/// macOS 14.4 and later only, and only when the process list answers: its
/// properties carry no version in the SDK and may be missing or empty on an
/// earlier system (S8). Without them the signal is off and the windows'
/// titles are all the detection has.
///
/// CoreAudio never calls a listener on `IsRunningInput` (S2: 0 out of 4).
/// The listeners that do fire are only wake-ups: the process list, each
/// input device's `IsRunningSomewhere` (~50 ms after an input opens), each
/// process's input `Devices`. A wake-up reads the list ~150 ms later, once
/// the burst settles, and while any input runs somewhere it is read again
/// every 2 s: a device may say it runs long after its last user closed it,
/// so an end is read process by process, never from the device.
///
/// A reading costs ~5 ms for 30 processes: `IsRunningInput` is the only
/// property read every time; each object's PID and bundle never change, and
/// the app behind a process is looked for only once it records. Our own
/// process is left out by PID (dictation and our recording use the
/// microphone too); system processes no app owns are kept with their own
/// bundle, so a provider can name them (FaceTime's calls run in
/// `avconferenced`).
///
/// Its own serial queue; each reading is handed to the main thread.
final class ForkMeetingMicWatcher {
    static let pollInterval: TimeInterval = 2
    /// Wake-ups come in bursts: one reading once they settle.
    static let settleDelay: TimeInterval = 0.15

    struct Cost: Equatable {
        var readings = 0
        var totalMilliseconds: Double = 0
        var maxMilliseconds: Double = 0
        var processes = 0

        var meanMilliseconds: Double { readings == 0 ? 0 : totalMilliseconds / Double(readings) }
    }

    /// Whether this Mac can say which process records: macOS 14.4 or later,
    /// and a process list that exists and is not empty. Read once.
    static let isSupported: Bool = {
        guard #available(macOS 14.4, *) else { return false }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = ForkMeetingMicWatcher.address(kAudioHardwarePropertyProcessObjectList)
        guard AudioObjectHasProperty(system, &address) else { return false }
        return !ForkMeetingMicWatcher.objects(system, kAudioHardwarePropertyProcessObjectList).isEmpty
    }()

    private let queue = DispatchQueue(label: "fork.meetings.microphones", qos: .utility)
    private let ownPID: pid_t
    private let onReading: ([ForkMeetingMicSignal]) -> Void

    private struct Process {
        let pid: pid_t
        let bundle: String?
    }

    private struct Owner {
        let pid: pid_t?
        let bundle: String?
    }

    private typealias Listener = (object: AudioObjectID, address: AudioObjectPropertyAddress,
                                  block: AudioObjectPropertyListenerBlock)

    // Queue only.
    private var running = false
    private var systemListeners: [Listener] = []
    private var deviceListeners: [AudioObjectID: Listener] = [:]
    private var processListeners: [AudioObjectID: Listener] = [:]
    private var processes: [AudioObjectID: Process] = [:]
    /// The app behind each process seen recording, while it lives.
    private var owners: [pid_t: Owner] = [:]
    private var deviceUIDs: [AudioObjectID: String] = [:]
    private var pendingRead: DispatchWorkItem?
    private var poll: DispatchSourceTimer?

    private let lock = NSLock()
    private var cost = Cost()

    /// `onReading` runs on the main thread.
    init(ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
         onReading: @escaping ([ForkMeetingMicSignal]) -> Void) {
        self.ownPID = ownPID
        self.onReading = onReading
    }

    deinit {
        poll?.cancel()
    }

    /// Listens and reads now. Nothing happens on a Mac without the signal
    /// (`isSupported`).
    func start() {
        guard Self.isSupported else { return }
        queue.async { [self] in
            guard !running else { return }
            running = true
            let system = AudioObjectID(kAudioObjectSystemObject)
            listen(system, kAudioHardwarePropertyProcessObjectList, into: &systemListeners)
            listen(system, kAudioHardwarePropertyDevices, into: &systemListeners)
            followDevices()
            read()
        }
    }

    /// Every listener and timer goes; what was learned is forgotten.
    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            pendingRead?.cancel()
            pendingRead = nil
            poll?.cancel()
            poll = nil
            for listener in systemListeners + Array(deviceListeners.values) + Array(processListeners.values) {
                remove(listener)
            }
            systemListeners = []
            deviceListeners = [:]
            processListeners = [:]
            processes = [:]
            owners = [:]
            deviceUIDs = [:]
        }
    }

    var measuredCost: Cost { lock.withLock { cost } }

    // MARK: - Wake-ups

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        into list: inout [Listener]) {
        if let listener = makeListener(object, selector, scope: scope) { list.append(listener) }
    }

    private func makeListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Listener? {
        var address = Self.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.wake(selector) }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
        return (object, address, block)
    }

    private func remove(_ listener: Listener) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
    }

    private func wake(_ selector: AudioObjectPropertySelector) {
        guard running else { return }
        if selector == kAudioHardwarePropertyDevices { followDevices() }
        guard pendingRead == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRead = nil
            self?.read()
        }
        pendingRead = work
        queue.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// `IsRunningSomewhere` on every input device, plugged in since or not.
    private func followDevices() {
        let inputs = Set(Self.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
            .filter(Self.hasInput))
        for (device, listener) in deviceListeners where !inputs.contains(device) {
            remove(listener)
            deviceListeners[device] = nil
            deviceUIDs[device] = nil
        }
        for device in inputs where deviceListeners[device] == nil {
            deviceListeners[device] = makeListener(device, kAudioDevicePropertyDeviceIsRunningSomewhere)
        }
    }

    // MARK: - Reading

    private func read() {
        guard running else { return }
        let began = DispatchTime.now().uptimeNanoseconds
        let list = Self.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        let current = Set(list)
        // A process gone takes its cache and its listener along.
        for object in processes.keys where !current.contains(object) {
            processes[object] = nil
            if let listener = processListeners.removeValue(forKey: object) { remove(listener) }
        }
        var signals: [ForkMeetingMicSignal] = []
        var recording = Set<pid_t>()
        for object in list {
            let process = processes[object] ?? learn(object)
            guard process.pid > 0, process.pid != ownPID,
                  Self.uint32(object, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            recording.insert(process.pid)
            let owner = owners[process.pid] ?? findOwner(process.pid)
            guard owner.pid != ownPID else { continue }
            signals.append(ForkMeetingMicSignal(appBundle: owner.bundle, appPID: owner.pid, pid: process.pid,
                                                processBundle: process.bundle, inputDevice: inputDevice(of: object)))
        }
        owners = owners.filter { recording.contains($0.key) }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
        lock.withLock {
            cost.readings += 1
            cost.totalMilliseconds += milliseconds
            cost.maxMilliseconds = max(cost.maxMilliseconds, milliseconds)
            cost.processes = list.count
        }
        let deliver = onReading
        DispatchQueue.main.async { deliver(signals) }
        // Read again every 2 s while an input runs somewhere, ours included:
        // an end is only ever seen by reading.
        let inputRuns = !recording.isEmpty || deviceListeners.keys.contains {
            Self.uint32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
        }
        setPolling(inputRuns)
    }

    /// An object's PID and bundle, which never change, and its input
    /// devices' listener.
    private func learn(_ object: AudioObjectID) -> Process {
        var pid: pid_t = -1
        _ = Self.read(object, kAudioProcessPropertyPID, &pid)
        let process = Process(pid: pid, bundle: Self.string(object, kAudioProcessPropertyBundleID))
        processes[object] = process
        if processListeners[object] == nil {
            processListeners[object] = makeListener(object, kAudioProcessPropertyDevices,
                                                    scope: kAudioObjectPropertyScopeInput)
        }
        return process
    }

    /// The regular app the process belongs to (Chrome for its audio
    /// helper); none for a system process.
    private func findOwner(_ pid: pid_t) -> Owner {
        let app = ResponsibleProcess.regularAppOwner(of: pid)
        let owner = Owner(pid: app?.processIdentifier, bundle: app?.bundleIdentifier)
        owners[pid] = owner
        return owner
    }

    /// The first input device the process records from, by UID.
    private func inputDevice(of object: AudioObjectID) -> String? {
        guard let device = Self.objects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput).first
        else { return nil }
        if let uid = deviceUIDs[device] { return uid }
        let uid = Self.string(device, kAudioDevicePropertyDeviceUID)
        if let uid { deviceUIDs[device] = uid }
        return uid
    }

    private func setPolling(_ on: Bool) {
        if on, poll == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval,
                            leeway: .milliseconds(200))
            source.setEventHandler { [weak self] in self?.read() }
            poll = source
            source.resume()
        } else if !on, let source = poll {
            source.cancel()
            poll = nil
        }
    }

    // MARK: - CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        } == noErr
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var value: UInt32 = 0
        return read(object, selector, &value) ? value : 0
    }

    private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        let text = value.takeRetainedValue() as String
        return text.isEmpty ? nil : text
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}
