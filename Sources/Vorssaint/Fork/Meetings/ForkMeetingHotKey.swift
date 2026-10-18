// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Carbon.HIToolbox
import Foundation

/// The meetings' start and stop shortcut, as a Carbon hotkey like the
/// official Keep Awake one: unlike dictation's event tap it needs no
/// permission at all, which suits a feature that never asks for
/// Accessibility. Installed only while the feature is on with a usable
/// combination (`ForkMeetingService.syncHotKey`), removed otherwise.
///
/// Main thread only.
final class ForkMeetingHotKey {
    /// 'SwMt'. The dispatcher hands every registered hotkey to every
    /// handler, so the signature tells ours from the official ones.
    private static let signature: OSType = 0x5377_4D74
    private static let identifier: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private(set) var registered: GlobalShortcut?
    /// macOS refused the last combination asked for: another app holds it.
    private(set) var isRefused = false
    let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    /// Installs `shortcut`, or removes the hotkey when it is `nil`. Asking
    /// again for the one installed does nothing.
    func sync(_ shortcut: GlobalShortcut?) {
        guard let shortcut else {
            unregister()
            isRefused = false
            return
        }
        if hotKeyRef != nil, registered == shortcut { return }
        unregister()
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.carbonKeyCode, shortcut.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: Self.identifier),
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
            registered = shortcut
            isRefused = false
        } else {
            isRefused = true
        }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = nil
    }

    /// Once: the handler stays for the app's life, and only answers while a
    /// key is registered.
    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Another feature's key: handed back, so the dispatcher goes on
            // to its own handler.
            guard id.signature == ForkMeetingHotKey.signature, id.id == ForkMeetingHotKey.identifier else {
                return OSStatus(eventNotHandledErr)
            }
            let hotKey = Unmanaged<ForkMeetingHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.onPress() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }
}
