// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AVFoundation
import CoreAudio
import Foundation

/// A microphone the person can pick for dictation. `id` is the CoreAudio
/// device UID, which is also the `AVCaptureDevice` unique ID.
struct ForkDictationAudioDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let isBuiltIn: Bool
}

/// The machine's audio inputs, read from CoreAudio without changing which
/// one the system uses.
enum ForkDictationAudioDevices {
    /// The stored choice for the built-in microphone, the default.
    static let builtInChoice = "builtin"
    /// The stored choice for whatever input the system uses at the time.
    static let systemChoice = "system"

    /// Every device with at least one input channel, the built-in one first.
    static func inputs() -> [ForkDictationAudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(describe).sorted { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static var builtIn: ForkDictationAudioDevice? { inputs().first(where: \.isBuiltIn) }

    /// The capture device for a stored choice. A missing chosen device falls
    /// back to the built-in microphone, never to the system's input: with a
    /// headset on, that input is the headset, the one most likely to record
    /// silence and to drop its own playback to call quality.
    static func captureDevice(for choice: String) -> AVCaptureDevice? {
        if choice == systemChoice {
            return AVCaptureDevice.default(for: .audio) ?? builtInCaptureDevice()
        }
        if choice != builtInChoice, let device = AVCaptureDevice(uniqueID: choice) {
            return device
        }
        return builtInCaptureDevice() ?? AVCaptureDevice.default(for: .audio)
    }

    private static func builtInCaptureDevice() -> AVCaptureDevice? {
        builtIn.flatMap { AVCaptureDevice(uniqueID: $0.id) }
    }

    private static func describe(_ id: AudioDeviceID) -> ForkDictationAudioDevice? {
        guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        // The transport type, not the name: "Built-in" is translated
        // differently in each system language.
        return ForkDictationAudioDevice(
            id: uid,
            name: string(id, kAudioObjectPropertyName) ?? uid,
            isBuiltIn: transport(id) == kAudioDeviceTransportTypeBuiltIn)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return false }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }
}
