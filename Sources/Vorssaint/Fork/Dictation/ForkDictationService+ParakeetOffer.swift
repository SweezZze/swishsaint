// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit

/// Parakeet is offered by default: when dictation is turned on, and once per
/// Mac at a launch with dictation already on. A copy of the FluidAudio cache
/// is made without asking, since it downloads nothing.
extension ForkDictationService {
    /// A launch retries this often while a startup window or a dictation is
    /// in the way, then gives up until the next launch.
    private static let launchRetry: TimeInterval = 30
    private static let launchAttempts = 20

    func offerParakeetAtLaunch() {
        let defaults = UserDefaults.standard
        // The first launch belongs to the onboarding: the offer waits for the next.
        guard defaults.bool(forKey: DefaultsKey.hasOnboarded) else { return }
        // A copy needs no answer, so only a question waits for the windows
        // the app opens at startup (What's New, an alert) to close.
        let startupWindowOpen = NSApp.modalWindow != nil || NSApp.windows.contains {
            $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
        }
        let decision = decideParakeetOffer(.launch)
        let waits = (decision == .none && machine.isBusy) || (decision == .ask && startupWindowOpen)
        if waits, launchOfferAttempts < Self.launchAttempts {
            launchOfferAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchRetry) { [weak self] in
                self?.offerParakeetAtLaunch()
            }
            return
        }
        if waits { return }
        act(on: decision)
    }

    func offerParakeet(_ reason: ForkDictationParakeetOffer.Reason) {
        act(on: decideParakeetOffer(reason))
    }

    private func decideParakeetOffer(_ reason: ForkDictationParakeetOffer.Reason)
        -> ForkDictationParakeetOffer.Decision {
        let store = ForkParakeetModelStore.shared
        return ForkDictationParakeetOffer.decide(
            reason: reason, enabled: Self.isWanted, engine: ForkDictationEngines.setting,
            installed: engines.isParakeetInstalled, canClone: store.canCloneFromFluidAudioCache,
            alreadyOffered: UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationParakeetOffered),
            busy: machine.isBusy || store.isBusy || parakeetOfferAlert != nil)
    }

    private func act(on decision: ForkDictationParakeetOffer.Decision) {
        switch decision {
        case .none:
            return
        case .installSilently:
            UserDefaults.standard.set(true, forKey: ForkDefaultsKey.dictationParakeetOffered)
            log.info("Parakeet copied from the FluidAudio cache")
            ForkParakeetModelStore.shared.install()
        case .ask:
            UserDefaults.standard.set(true, forKey: ForkDefaultsKey.dictationParakeetOffered)
            askToInstallParakeet()
        }
    }

    private func askToInstallParakeet() {
        let text = ForkDictationStrings.current
        let store = ForkParakeetModelStore.shared
        let size = ByteCountFormatter.string(fromByteCount: max(0, store.totalBytes - store.resumableBytes),
                                             countStyle: .file)
        let alert = NSAlert()
        alert.messageText = text.parakeetOfferTitle
        alert.informativeText = text.parakeetOfferMessage(size)
        alert.addButton(withTitle: text.parakeetOfferInstall)
        alert.addButton(withTitle: text.parakeetOfferLater)
        // Not runModal: a modal loop would hold back the shortcuts and timers
        // of the whole app until the person answers.
        NSApp.activate(ignoringOtherApps: true)
        parakeetOfferAlert = NonModalAlert.present(alert) { [weak self] response in
            self?.parakeetOfferAlert = nil
            guard response == .alertFirstButtonReturn else { return }
            ForkParakeetModelStore.shared.install()
            ForkSettingsPages.open(.dictation)
            (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
        }
    }
}
