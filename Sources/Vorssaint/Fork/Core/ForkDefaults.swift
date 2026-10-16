// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

/// The fork's preference keys, all under `fork.`: the official app never
/// writes there, so a merge of the official code can never collide with them.
enum ForkDefaultsKey {
    static let gesturesEnabled = "fork.gestures.enabled"
    static let linkedResizeEnabled = "fork.gestures.linkedResize"
    static let disabledGestures = "fork.gestures.disabled"
    static let centerSizeStep = "fork.gestures.centerSizeStep"
    static let swipeSensitivityStep = "fork.gestures.swipeSensitivityStep"
    static let pinchSensitivityStep = "fork.gestures.pinchSensitivityStep"
    static let stepPauseStep = "fork.gestures.stepPauseStep"
    static let cancelDelayStep = "fork.gestures.cancelDelayStep"
    /// Off: a still gesture is never given up, only Escape or the lift end it.
    static let cancelEnabled = "fork.gestures.cancelEnabled"
    /// The keys held for the six-zone grid, and for the stronger gestures:
    /// `ForkTrackpadModifierKeys` raw values.
    static let gridModifierKeys = "fork.gestures.gridModifierKeys"
    static let strongerModifierKeys = "fork.gestures.strongerModifierKeys"
    static let titlebarBandStep = "fork.gestures.titlebarBandStep"
    static let previewEnabled = "fork.gestures.preview"
    static let hapticsEnabled = "fork.gestures.haptics"
    /// The build the person answered "Later" for. Machine state: kept out
    /// of the settings backup.
    static let updatePostponedBuild = "fork.update.postponedBuild"
}

enum ForkDefaults {
    static let registered: [String: Any] = [
        ForkDefaultsKey.gesturesEnabled: false,
        ForkDefaultsKey.linkedResizeEnabled: false,
        ForkDefaultsKey.disabledGestures: "",
        ForkDefaultsKey.centerSizeStep: ForkTrackpadTuning.centerSize.defaultStep,
        ForkDefaultsKey.swipeSensitivityStep: ForkTrackpadTuning.swipeSensitivity.defaultStep,
        ForkDefaultsKey.pinchSensitivityStep: ForkTrackpadTuning.pinchSensitivity.defaultStep,
        ForkDefaultsKey.stepPauseStep: ForkTrackpadTuning.stepPause.defaultStep,
        ForkDefaultsKey.cancelDelayStep: ForkTrackpadTuning.cancelDelay.defaultStep,
        ForkDefaultsKey.cancelEnabled: true,
        ForkDefaultsKey.gridModifierKeys: ForkTrackpadModifierKeys.gridDefault.rawValue,
        ForkDefaultsKey.strongerModifierKeys: ForkTrackpadModifierKeys.strongerDefault.rawValue,
        ForkDefaultsKey.titlebarBandStep: ForkTrackpadTuning.titlebarBand.defaultStep,
        ForkDefaultsKey.previewEnabled: true,
        ForkDefaultsKey.hapticsEnabled: true,
    ]

    /// Where each setting lived in the test builds made before the fork
    /// ("Vorssaint (Developer)"): a backup exported from one of them still
    /// carries these names.
    static let legacyKeys: [String: String] = [
        "windowTrackpadGesturesEnabled": ForkDefaultsKey.gesturesEnabled,
        "windowLinkedResizeEnabled": ForkDefaultsKey.linkedResizeEnabled,
        "windowTrackpadDisabledGestures": ForkDefaultsKey.disabledGestures,
        "windowTrackpadCenterSizeStep": ForkDefaultsKey.centerSizeStep,
        "windowTrackpadSwipeSensitivityStep": ForkDefaultsKey.swipeSensitivityStep,
        "windowTrackpadPinchSensitivityStep": ForkDefaultsKey.pinchSensitivityStep,
        "windowTrackpadStepPauseStep": ForkDefaultsKey.stepPauseStep,
        "windowTrackpadCancelDelayStep": ForkDefaultsKey.cancelDelayStep,
        "windowTrackpadTitlebarBandStep": ForkDefaultsKey.titlebarBandStep,
        "windowTrackpadPreviewEnabled": ForkDefaultsKey.previewEnabled,
        "windowTrackpadHapticsEnabled": ForkDefaultsKey.hapticsEnabled,
    ]

    /// What a settings backup may bring back for the fork (`ForkBackup`):
    /// every fork setting, and the old names so a backup from a pre-fork
    /// test build imports too (`register` then moves them to their new names).
    static var backupKeys: Set<String> {
        Set(registered.keys).union(legacyKeys.keys)
    }

    static func register(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: registered)
        migrateLegacyKeys(defaults)
    }

    /// Moves each old-named value to its new name and removes the old name.
    /// An old name only appears right after importing such a backup, so its
    /// value is the one just asked for.
    static func migrateLegacyKeys(_ defaults: UserDefaults) {
        for (old, new) in legacyKeys {
            guard let value = defaults.object(forKey: old) else { continue }
            defaults.set(value, forKey: new)
            defaults.removeObject(forKey: old)
        }
    }
}
